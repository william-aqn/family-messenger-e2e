// Package auth implements device tokens, the HTTP authentication middleware
// and a small per-IP rate limiter.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

// ErrUnauthorized is returned for missing or invalid tokens.
var ErrUnauthorized = errors.New("unauthorized")

// ErrDisabled is returned when the account was disabled by an administrator.
var ErrDisabled = errors.New("account disabled")

// Principal is the authenticated device and its account.
type Principal struct {
	AccountID string
	DeviceID  string
	Username  string
	SignPub   []byte
	EncPub    []byte
	IsAdmin   bool
	IsBot     bool
}

type ctxKey struct{}

// WithPrincipal attaches a principal to the context.
func WithPrincipal(ctx context.Context, p *Principal) context.Context {
	return context.WithValue(ctx, ctxKey{}, p)
}

// FromContext returns the principal attached by the middleware.
func FromContext(ctx context.Context) (*Principal, bool) {
	p, ok := ctx.Value(ctxKey{}).(*Principal)
	return p, ok
}

// NewToken creates a random device token and the hash the server stores.
func NewToken() (token string, hash []byte, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, err
	}
	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, HashToken(token), nil
}

// HashToken returns SHA-256 of the token; only the hash is stored.
func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// Authenticator resolves tokens against the store.
type Authenticator struct {
	store *store.Store

	mu      sync.Mutex
	touched map[string]time.Time
}

// New creates an Authenticator.
func New(st *store.Store) *Authenticator {
	return &Authenticator{store: st, touched: make(map[string]time.Time)}
}

// Authenticate resolves a bearer token to a principal.
func (a *Authenticator) Authenticate(ctx context.Context, token string) (*Principal, error) {
	if token == "" {
		return nil, ErrUnauthorized
	}
	dev, acct, err := a.store.DeviceByTokenHash(ctx, HashToken(token))
	if errors.Is(err, store.ErrNotFound) {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if acct.Disabled {
		return nil, ErrDisabled
	}
	a.touch(ctx, dev.ID)
	return &Principal{
		AccountID: acct.ID, DeviceID: dev.ID, Username: acct.Username,
		SignPub: acct.SignPub, EncPub: acct.EncPub, IsAdmin: acct.IsAdmin, IsBot: acct.IsBot,
	}, nil
}

// touch updates last_seen at most once per minute per device.
func (a *Authenticator) touch(ctx context.Context, deviceID string) {
	now := time.Now()
	a.mu.Lock()
	last, ok := a.touched[deviceID]
	if ok && now.Sub(last) < time.Minute {
		a.mu.Unlock()
		return
	}
	a.touched[deviceID] = now
	if len(a.touched) > 10000 {
		for id, t := range a.touched {
			if now.Sub(t) > time.Hour {
				delete(a.touched, id)
			}
		}
	}
	a.mu.Unlock()
	_ = a.store.TouchDevice(ctx, deviceID, now.Unix())
}

func writeAuthError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	if status == http.StatusUnauthorized {
		w.Header().Set("WWW-Authenticate", "Bearer")
	}
	w.WriteHeader(status)
	_, _ = w.Write([]byte(`{"error":{"code":"` + code + `","message":"` + msg + `"}}`))
}

// Middleware requires a valid "Authorization: Bearer <token>" header.
func (a *Authenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(h, "Bearer ")
		if !ok {
			writeAuthError(w, http.StatusUnauthorized, "unauthorized", "authentication required")
			return
		}
		p, err := a.Authenticate(r.Context(), strings.TrimSpace(token))
		switch {
		case err == nil:
			next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
		case errors.Is(err, ErrUnauthorized):
			writeAuthError(w, http.StatusUnauthorized, "unauthorized", "invalid token")
		case errors.Is(err, ErrDisabled):
			writeAuthError(w, http.StatusForbidden, "account_disabled", "this account has been disabled")
		default:
			writeAuthError(w, http.StatusInternalServerError, "internal", "internal error")
		}
	})
}

// Limiter is a per-key token bucket.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	burst   float64
	rate    float64 // tokens per second
}

type bucket struct {
	tokens float64
	last   time.Time
}

// NewLimiter allows burst requests immediately and rate requests per second
// afterwards, per key.
func NewLimiter(burst int, rate float64) *Limiter {
	return &Limiter{buckets: make(map[string]*bucket), burst: float64(burst), rate: rate}
}

// Allow reports whether a request for key may proceed.
func (l *Limiter) Allow(key string) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok {
		if len(l.buckets) > 10000 {
			for k, v := range l.buckets {
				if now.Sub(v.last) > 10*time.Minute {
					delete(l.buckets, k)
				}
			}
		}
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// Middleware limits by client IP (X-Forwarded-For first hop when present,
// which is correct behind the bundled reverse proxy).
func (l *Limiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !l.Allow(ClientIP(r)) {
			w.Header().Set("Retry-After", "10")
			writeAuthError(w, http.StatusTooManyRequests, "rate_limited", "too many requests")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ClientIP extracts the client address for logging and rate limiting.
func ClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if first, _, ok := strings.Cut(xff, ","); ok {
			return strings.TrimSpace(first)
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
