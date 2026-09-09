// Package settings holds the runtime settings an administrator can change
// without restarting the server. Values are persisted in the database and
// fall back to configuration defaults.
package settings

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"

	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

// Settings is the typed view of the settings table.
type Settings struct {
	Registration       string `json:"registration"`         // open | invite | closed
	MaxAttachmentBytes int64  `json:"max_attachment_bytes"` // upload limit per file
	RetentionDays      int64  `json:"retention_days"`       // global cap, 0 = keep forever
	AllowBots          bool   `json:"allow_bots"`           // users may create bots
	MaxGroupMembers    int    `json:"max_group_members"`    // 2..100
	Announcement       string `json:"announcement"`         // banner shown to everyone
	UserDirectory      bool   `json:"user_directory"`       // members may list users and get name suggestions
}

// Defaults returns the built-in defaults with the given registration mode.
func Defaults(registration string) Settings {
	return Settings{
		Registration:       registration,
		MaxAttachmentBytes: 50 << 20,
		RetentionDays:      0,
		AllowBots:          true,
		MaxGroupMembers:    100,
		Announcement:       "",
		UserDirectory:      true,
	}
}

// Manager caches the settings in memory and persists changes.
type Manager struct {
	store *store.Store
	mu    sync.RWMutex
	cur   Settings
}

// Load reads the stored settings on top of the defaults.
func Load(ctx context.Context, st *store.Store, defaults Settings) (*Manager, error) {
	kv, err := st.LoadSettings(ctx)
	if err != nil {
		return nil, err
	}
	m := &Manager{store: st, cur: defaults}
	m.cur = apply(m.cur, kv)
	return m, nil
}

func apply(s Settings, kv map[string]string) Settings {
	if v, ok := kv["registration"]; ok {
		s.Registration = v
	}
	if v, ok := kv["max_attachment_bytes"]; ok {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			s.MaxAttachmentBytes = n
		}
	}
	if v, ok := kv["retention_days"]; ok {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			s.RetentionDays = n
		}
	}
	if v, ok := kv["allow_bots"]; ok {
		s.AllowBots = v == "1"
	}
	if v, ok := kv["max_group_members"]; ok {
		if n, err := strconv.Atoi(v); err == nil {
			s.MaxGroupMembers = n
		}
	}
	if v, ok := kv["announcement"]; ok {
		s.Announcement = v
	}
	if v, ok := kv["user_directory"]; ok {
		s.UserDirectory = v == "1"
	}
	return s
}

func boolFlag(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

// Get returns a copy of the current settings.
func (m *Manager) Get() Settings {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.cur
}

// Validate checks ranges and normalises values.
func Validate(s *Settings) error {
	s.Registration = strings.ToLower(strings.TrimSpace(s.Registration))
	switch s.Registration {
	case "open", "invite", "closed":
	default:
		return errors.New("registration must be open, invite or closed")
	}
	if s.MaxAttachmentBytes < 0 || s.MaxAttachmentBytes > 2<<30 {
		return errors.New("max_attachment_bytes must be between 0 and 2 GiB")
	}
	if s.RetentionDays < 0 || s.RetentionDays > 3650 {
		return errors.New("retention_days must be between 0 and 3650")
	}
	if s.MaxGroupMembers < 2 || s.MaxGroupMembers > 100 {
		return errors.New("max_group_members must be between 2 and 100")
	}
	if len(s.Announcement) > 2000 {
		return errors.New("announcement is too long")
	}
	return nil
}

// Update validates, persists and activates new settings.
func (m *Manager) Update(ctx context.Context, s Settings) error {
	if err := Validate(&s); err != nil {
		return err
	}
	kv := map[string]string{
		"registration":         s.Registration,
		"max_attachment_bytes": strconv.FormatInt(s.MaxAttachmentBytes, 10),
		"retention_days":       strconv.FormatInt(s.RetentionDays, 10),
		"allow_bots":           boolFlag(s.AllowBots),
		"max_group_members":    strconv.Itoa(s.MaxGroupMembers),
		"announcement":         s.Announcement,
		"user_directory":       boolFlag(s.UserDirectory),
	}
	if err := m.store.SaveSettings(ctx, kv); err != nil {
		return err
	}
	m.mu.Lock()
	m.cur = s
	m.mu.Unlock()
	return nil
}
