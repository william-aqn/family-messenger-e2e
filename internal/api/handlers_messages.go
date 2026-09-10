package api

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/auth"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/internal/ws"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

// messageView is a stored or relayed envelope as delivered to clients.
//
// A deletion record (PROTOCOL.md §6.3) uses the same shape with an empty
// env and sig: deleted_seq names the removed message and deleted_sender its
// author, while sender_account is whoever deleted it.
type messageView struct {
	ConvID        string `json:"conv_id"`
	Seq           int64  `json:"seq"`
	SenderAccount string `json:"sender_account"`
	SenderDevice  string `json:"sender_device"`
	ClientMsgID   string `json:"client_msg_id"`
	Env           []byte `json:"env"`
	Sig           []byte `json:"sig"`
	ServerTS      int64  `json:"server_ts"`
	DeletedSeq    int64  `json:"deleted_seq,omitempty"`
	DeletedSender string `json:"deleted_sender,omitempty"`
}

func viewOf(m *store.Message) messageView {
	return messageView{
		ConvID: m.ConvID, Seq: m.Seq, SenderAccount: m.SenderAccount, SenderDevice: m.SenderDevice, ClientMsgID: m.ClientID,
		Env: m.Env, Sig: m.Sig, ServerTS: m.ServerTS, DeletedSeq: m.DeletedSeq, DeletedSender: m.DeletedSender,
	}
}

type sendRequest struct {
	Env []byte `json:"env"`
	Sig []byte `json:"sig"`
}

type sendResult struct {
	ConvID      string `json:"conv_id"`
	ClientMsgID string `json:"client_msg_id"`
	Seq         int64  `json:"seq"`
	ServerTS    int64  `json:"server_ts"`
	Duplicate   bool   `json:"duplicate,omitempty"`
	Ephemeral   bool   `json:"ephemeral,omitempty"`
}

// sendEnvelope performs the server-side checks of PROTOCOL.md §5.1, stores
// (or only relays) the envelope and fans it out to every member device.
func (s *Server) sendEnvelope(ctx context.Context, p *auth.Principal, convID string, env, sig []byte) (*sendResult, error) {
	if len(env) > e2e.MaxEnvelopeSize {
		return nil, &apiError{http.StatusRequestEntityTooLarge, "envelope_too_large", "envelope exceeds 64 KiB"}
	}
	if len(sig) != e2e.SignatureSize {
		return nil, badRequest("bad_signature", "signature must be 64 bytes")
	}
	e, err := e2e.Parse(env)
	if err != nil {
		return nil, badRequest("invalid_envelope", err.Error())
	}
	if e.ConvID.String() != convID {
		return nil, badRequest("conversation_mismatch", "envelope conv_id does not match the conversation")
	}
	if e.SenderAccount.String() != p.AccountID || e.SenderDevice.String() != p.DeviceID {
		return nil, forbidden("sender_mismatch", "envelope sender does not match the authenticated device")
	}
	var signPub [32]byte
	copy(signPub[:], p.SignPub)
	if !e2e.VerifyEnvelope(signPub, env, sig) {
		return nil, badRequest("bad_signature", "envelope signature does not verify")
	}
	recipients := make([]string, 0, len(e.Recipients))
	seen := make(map[string]bool, len(e.Recipients))
	for _, rc := range e.Recipients {
		id := rc.Account.String()
		if !seen[id] {
			seen[id] = true
			recipients = append(recipients, id)
		}
	}
	now := time.Now().UnixMilli()
	view := messageView{ConvID: convID, SenderAccount: p.AccountID, SenderDevice: p.DeviceID, ClientMsgID: e.ClientMsgID.String(), Env: env, Sig: sig, ServerTS: now}

	if e.Flags&e2e.FlagEphemeral != 0 {
		members, err := s.store.ValidateSend(ctx, convID, p.AccountID, recipients)
		if err != nil {
			return nil, err
		}
		s.hub.SendToAccounts(members, ws.NewFrame("signal", view))
		return &sendResult{ConvID: convID, ClientMsgID: view.ClientMsgID, ServerTS: now, Ephemeral: true}, nil
	}

	msg := &store.Message{ConvID: convID, SenderAccount: p.AccountID, SenderDevice: p.DeviceID, ClientID: view.ClientMsgID, Env: env, Sig: sig, ServerTS: now}
	seq, dup, members, err := s.store.AppendMessage(ctx, msg, recipients)
	if err != nil {
		return nil, err
	}
	if !dup {
		view.Seq = seq
		s.hub.SendToAccounts(members, ws.NewFrame("message", view))
		s.bots.onStored(ctx, p, e, convID, seq, now, members)
	}
	return &sendResult{ConvID: convID, ClientMsgID: view.ClientMsgID, Seq: seq, ServerTS: now, Duplicate: dup}, nil
}

func (s *Server) sendMessage(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	var req sendRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	res, err := s.sendEnvelope(r.Context(), p, id, req.Env, req.Sig)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	status := http.StatusCreated
	if res.Duplicate || res.Ephemeral {
		status = http.StatusOK
	}
	writeJSON(w, status, res)
}

func queryInt(r *http.Request, name string, def int64) int64 {
	v := r.URL.Query().Get(name)
	if v == "" {
		return def
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return def
	}
	return n
}

func (s *Server) listMessages(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	conv, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	after := queryInt(r, "after", 0)
	limit := queryInt(r, "limit", 100)
	if limit < 1 {
		limit = 1
	}
	if limit > 200 {
		limit = 200
	}
	msgs, err := s.store.Messages(r.Context(), id, after, conv.Me.JoinedSeq, limit+1)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	hasMore := int64(len(msgs)) > limit
	if hasMore {
		msgs = msgs[:limit]
	}
	views := make([]messageView, 0, len(msgs))
	for i := range msgs {
		views = append(views, viewOf(&msgs[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": views, "has_more": hasMore, "last_seq": conv.LastSeq})
}

// deleteMessage removes a stored message for everyone (PROTOCOL.md §6.3).
// The sender may delete their own messages; an administrator may delete any
// message, member of the conversation or not. The ciphertext is dropped and
// a deletion record is appended to the sequence, so every device learns
// about it in order.
func (s *Server) deleteMessage(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	seq, err := strconv.ParseInt(r.PathValue("seq"), 10, 64)
	if err != nil || seq <= 0 {
		writeError(w, s.log, notFound("not_found", "no such message"))
		return
	}
	if !p.IsAdmin {
		if _, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID); err != nil {
			writeError(w, s.log, err)
			return
		}
	}
	m, err := s.store.Message(r.Context(), id, seq)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if m.SenderAccount != p.AccountID && !p.IsAdmin {
		writeError(w, s.log, forbidden("not_your_message", "only the sender or an administrator can delete this message"))
		return
	}
	rec, err := s.store.DeleteMessage(r.Context(), id, seq, p.AccountID, p.DeviceID, newID(), time.Now().UnixMilli())
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	members, err := s.store.MemberAccountIDs(r.Context(), id)
	if err != nil {
		s.log.Error("cannot list members after deletion", "err", err)
	}
	s.hub.SendToAccounts(members, ws.NewFrame("message", viewOf(rec)))
	s.bots.onDeleted(r.Context(), p, m, members)
	if m.SenderAccount != p.AccountID {
		s.log.Info("message deleted by an administrator", "by", p.Username, "conv", id, "seq", seq)
	}
	w.WriteHeader(http.StatusNoContent)
}
