package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/william-aqn/family-messenger-e2e/internal/ws"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

type wsSendRequest struct {
	Ref    string `json:"ref,omitempty"`
	ConvID string `json:"conv_id"`
	Env    []byte `json:"env"`
	Sig    []byte `json:"sig"`
}

type wsError struct {
	Ref     string `json:"ref,omitempty"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type wsAck struct {
	Ref string `json:"ref,omitempty"`
	*sendResult
}

// handleWS upgrades the connection, authenticates it with the first frame
// ({"t":"auth","d":{"token":...}}) and serves it until it closes.
func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	// Authentication is by bearer token inside the first frame, not by
	// cookies, so cross-origin requests cannot ride on browser credentials.
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		s.log.Debug("websocket accept failed", "err", err)
		return
	}
	c.SetReadLimit(256 << 10)
	ctx := r.Context()

	actx, cancel := context.WithTimeout(ctx, 10*time.Second)
	_, data, err := c.Read(actx)
	cancel()
	var first ws.Frame
	if err != nil || json.Unmarshal(data, &first) != nil || first.T != "auth" {
		c.Close(websocket.StatusPolicyViolation, "first frame must be auth")
		return
	}
	var a struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(first.D, &a)
	p, err := s.auth.Authenticate(ctx, a.Token)
	if err != nil {
		c.Close(websocket.StatusPolicyViolation, "invalid token")
		return
	}

	conn := ws.NewConn(c, p.AccountID, p.DeviceID)
	s.hub.Add(conn)
	defer s.hub.Remove(conn)
	go conn.WriteLoop(ctx)
	conn.Send(ws.NewFrame("hello", map[string]any{"account_id": p.AccountID, "device_id": p.DeviceID, "server_ts": time.Now().UnixMilli(), "version": Version}))

	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			conn.Close(websocket.StatusNormalClosure, "")
			return
		}
		var f ws.Frame
		if err := json.Unmarshal(data, &f); err != nil {
			conn.Send(ws.NewFrame("error", wsError{Code: "invalid_frame", Message: "frames must be JSON objects {t, d}"}))
			continue
		}
		switch f.T {
		case "send":
			var req wsSendRequest
			if err := json.Unmarshal(f.D, &req); err != nil {
				conn.Send(ws.NewFrame("error", wsError{Code: "invalid_frame", Message: "send needs conv_id, env and sig"}))
				continue
			}
			convID, err := e2e.ParseID(req.ConvID)
			if err != nil {
				conn.Send(ws.NewFrame("error", wsError{Ref: req.Ref, Code: "not_found", Message: "no such conversation"}))
				continue
			}
			res, err := s.sendEnvelope(ctx, p, convID.String(), req.Env, req.Sig)
			if err != nil {
				ae := toAPIError(err)
				if ae == nil {
					s.log.Error("websocket send failed", "err", err)
					ae = &apiError{http.StatusInternalServerError, "internal", "internal error"}
				}
				conn.Send(ws.NewFrame("error", wsError{Ref: req.Ref, Code: ae.Code, Message: ae.Message}))
				continue
			}
			conn.Send(ws.NewFrame("ack", wsAck{Ref: req.Ref, sendResult: res}))
		case "ping":
			conn.Send(ws.NewFrame("pong", map[string]int64{"server_ts": time.Now().UnixMilli()}))
		default:
			conn.Send(ws.NewFrame("error", wsError{Code: "unknown_type", Message: "unknown frame type " + f.T}))
		}
	}
}
