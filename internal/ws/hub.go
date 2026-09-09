// Package ws holds WebSocket connections and fans frames out to devices.
package ws

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Frame is the JSON envelope of every WebSocket message: {"t": type, "d": data}.
type Frame struct {
	T string          `json:"t"`
	D json.RawMessage `json:"d,omitempty"`
}

// NewFrame marshals d into a frame of type t.
func NewFrame(t string, d any) Frame {
	if d == nil {
		return Frame{T: t}
	}
	b, err := json.Marshal(d)
	if err != nil {
		panic(err)
	}
	return Frame{T: t, D: b}
}

// Conn is one authenticated WebSocket connection.
type Conn struct {
	AccountID string
	DeviceID  string

	ws        *websocket.Conn
	out       chan []byte
	done      chan struct{}
	closeOnce sync.Once
}

// NewConn wraps an accepted, authenticated connection.
func NewConn(c *websocket.Conn, accountID, deviceID string) *Conn {
	return &Conn{
		AccountID: accountID,
		DeviceID:  deviceID,
		ws:        c,
		out:       make(chan []byte, 256),
		done:      make(chan struct{}),
	}
}

// Send queues a frame without blocking. A consumer that cannot keep up is
// disconnected; it will resynchronise on reconnect.
func (c *Conn) Send(f Frame) {
	b, err := json.Marshal(f)
	if err != nil {
		return
	}
	c.sendBytes(b)
}

func (c *Conn) sendBytes(b []byte) {
	select {
	case <-c.done:
	case c.out <- b:
	default:
		c.Close(websocket.StatusPolicyViolation, "slow consumer")
	}
}

// Close terminates the connection once.
func (c *Conn) Close(code websocket.StatusCode, reason string) {
	c.closeOnce.Do(func() {
		close(c.done)
		_ = c.ws.Close(code, reason)
	})
}

// Done is closed when the connection is closed.
func (c *Conn) Done() <-chan struct{} { return c.done }

// WriteLoop writes queued frames and pings the peer until the connection
// closes. Run it in its own goroutine.
func (c *Conn) WriteLoop(ctx context.Context) {
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-ctx.Done():
			c.Close(websocket.StatusGoingAway, "server shutting down")
			return
		case b := <-c.out:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.ws.Write(wctx, websocket.MessageText, b)
			cancel()
			if err != nil {
				c.Close(websocket.StatusAbnormalClosure, "write failed")
				return
			}
		case <-ping.C:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.ws.Ping(wctx)
			cancel()
			if err != nil {
				c.Close(websocket.StatusAbnormalClosure, "ping failed")
				return
			}
		}
	}
}

// Hub indexes live connections by account and device.
type Hub struct {
	mu        sync.RWMutex
	byAccount map[string]map[*Conn]struct{}
	byDevice  map[string]map[*Conn]struct{}
}

// NewHub creates an empty hub.
func NewHub() *Hub {
	return &Hub{byAccount: make(map[string]map[*Conn]struct{}), byDevice: make(map[string]map[*Conn]struct{})}
}

// Add registers a connection.
func (h *Hub) Add(c *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	add(h.byAccount, c.AccountID, c)
	add(h.byDevice, c.DeviceID, c)
}

// Remove unregisters a connection.
func (h *Hub) Remove(c *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	remove(h.byAccount, c.AccountID, c)
	remove(h.byDevice, c.DeviceID, c)
}

func add(m map[string]map[*Conn]struct{}, key string, c *Conn) {
	set, ok := m[key]
	if !ok {
		set = make(map[*Conn]struct{})
		m[key] = set
	}
	set[c] = struct{}{}
}

func remove(m map[string]map[*Conn]struct{}, key string, c *Conn) {
	if set, ok := m[key]; ok {
		delete(set, c)
		if len(set) == 0 {
			delete(m, key)
		}
	}
}

// SendToAccounts delivers a frame to every connection of the given accounts.
func (h *Hub) SendToAccounts(accounts []string, f Frame) {
	b, err := json.Marshal(f)
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, id := range accounts {
		for c := range h.byAccount[id] {
			c.sendBytes(b)
		}
	}
}

// SendToAccount delivers a frame to every connection of one account.
func (h *Hub) SendToAccount(account string, f Frame) {
	h.SendToAccounts([]string{account}, f)
}

// SendToDevice delivers a frame to every connection of one device.
func (h *Hub) SendToDevice(device string, f Frame) {
	b, err := json.Marshal(f)
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.byDevice[device] {
		c.sendBytes(b)
	}
}

// CloseDevice disconnects every connection of a device (logout).
func (h *Hub) CloseDevice(device string) {
	h.mu.RLock()
	conns := make([]*Conn, 0, len(h.byDevice[device]))
	for c := range h.byDevice[device] {
		conns = append(conns, c)
	}
	h.mu.RUnlock()
	for _, c := range conns {
		c.Close(websocket.StatusPolicyViolation, "logged out")
	}
}

// Online reports whether the account has at least one connection.
func (h *Hub) Online(account string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.byAccount[account]) > 0
}

// ConnectionCount returns the number of live connections.
func (h *Hub) ConnectionCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	n := 0
	for _, set := range h.byDevice {
		n += len(set)
	}
	return n
}

// CloseAll disconnects everyone (shutdown).
func (h *Hub) CloseAll() {
	h.mu.RLock()
	conns := make([]*Conn, 0)
	for _, set := range h.byDevice {
		for c := range set {
			conns = append(conns, c)
		}
	}
	h.mu.RUnlock()
	for _, c := range conns {
		c.Close(websocket.StatusGoingAway, "server shutting down")
	}
}
