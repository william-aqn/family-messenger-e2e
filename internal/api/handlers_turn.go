package api

import (
	"net/http"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/turn"
)

// iceServer matches the WebRTC RTCIceServer dictionary.
type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

func (s *Server) turn(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	servers := make([]iceServer, 0, 2)
	if len(s.cfg.STUNURLs) > 0 {
		servers = append(servers, iceServer{URLs: s.cfg.STUNURLs})
	}
	ttl := 0
	if s.cfg.TURNSecret != "" && len(s.cfg.TURNURLs) > 0 {
		username, credential := turn.Credentials(s.cfg.TURNSecret, p.AccountID, s.cfg.TURNTTL, time.Now())
		servers = append(servers, iceServer{URLs: s.cfg.TURNURLs, Username: username, Credential: credential})
		ttl = int(s.cfg.TURNTTL.Seconds())
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"ice_servers": servers, "ttl": ttl})
}
