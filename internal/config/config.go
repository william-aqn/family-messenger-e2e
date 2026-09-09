// Package config loads server configuration from environment variables.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Config is the runtime configuration of the server.
type Config struct {
	Addr         string        // MSGR_ADDR, listen address (default ":8080")
	DataDir      string        // MSGR_DATA_DIR, SQLite database and secrets (default "./data")
	PublicURL    string        // MSGR_PUBLIC_URL, e.g. https://chat.example.com (informational)
	Registration string        // MSGR_REGISTRATION: open | invite | closed (default "invite")
	ServerSecret []byte        // MSGR_SERVER_SECRET, or generated once and stored in DataDir
	TURNSecret   string        // MSGR_TURN_SECRET, coturn static-auth-secret
	TURNURLs     []string      // MSGR_TURN_URLS, comma separated turn:/turns: URLs
	TURNTTL      time.Duration // MSGR_TURN_TTL, lifetime of issued TURN credentials (default 1h)
	STUNURLs     []string      // MSGR_STUN_URLS, comma separated stun: URLs
	WebDir       string        // MSGR_WEB_DIR, serve the web UI from this directory instead of the embedded build
	LogJSON      bool          // MSGR_LOG_JSON=1 for JSON logs
	Debug        bool          // MSGR_DEBUG=1 for debug logging
}

// FromEnv builds a Config from the environment and makes sure DataDir and
// the server secret exist.
func FromEnv() (*Config, error) {
	c := &Config{
		Addr:         getenv("MSGR_ADDR", ":8080"),
		DataDir:      getenv("MSGR_DATA_DIR", "./data"),
		PublicURL:    strings.TrimRight(os.Getenv("MSGR_PUBLIC_URL"), "/"),
		Registration: getenv("MSGR_REGISTRATION", "invite"),
		TURNSecret:   os.Getenv("MSGR_TURN_SECRET"),
		TURNURLs:     splitList(os.Getenv("MSGR_TURN_URLS")),
		STUNURLs:     splitList(os.Getenv("MSGR_STUN_URLS")),
		WebDir:       os.Getenv("MSGR_WEB_DIR"),
		LogJSON:      os.Getenv("MSGR_LOG_JSON") == "1",
		Debug:        os.Getenv("MSGR_DEBUG") == "1",
	}
	switch c.Registration {
	case "open", "invite", "closed":
	default:
		return nil, fmt.Errorf("MSGR_REGISTRATION must be open, invite or closed, got %q", c.Registration)
	}
	ttl, err := time.ParseDuration(getenv("MSGR_TURN_TTL", "1h"))
	if err != nil {
		return nil, fmt.Errorf("MSGR_TURN_TTL: %w", err)
	}
	c.TURNTTL = ttl
	if err := os.MkdirAll(c.DataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	secret, err := loadSecret(os.Getenv("MSGR_SERVER_SECRET"), filepath.Join(c.DataDir, "server.secret"))
	if err != nil {
		return nil, err
	}
	c.ServerSecret = secret
	return c, nil
}

// DBPath is the SQLite database file.
func (c *Config) DBPath() string { return filepath.Join(c.DataDir, "family-messenger.db") }

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// loadSecret returns the configured secret, or a random one persisted in
// file so that it survives restarts.
func loadSecret(env, file string) ([]byte, error) {
	if env != "" {
		return []byte(env), nil
	}
	if b, err := os.ReadFile(file); err == nil && len(strings.TrimSpace(string(b))) >= 32 {
		return []byte(strings.TrimSpace(string(b))), nil
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read %s: %w", file, err)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	secret := hex.EncodeToString(raw)
	if err := os.WriteFile(file, []byte(secret+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("write %s: %w", file, err)
	}
	return []byte(secret), nil
}
