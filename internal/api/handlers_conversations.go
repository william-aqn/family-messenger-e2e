package api

import (
	"errors"
	"net/http"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/internal/ws"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

type memberView struct {
	ID          string `json:"id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name,omitempty"`
	Role        string `json:"role"`
	JoinedSeq   int64  `json:"joined_seq"`
	SignPub     []byte `json:"sign_pub"`
	EncPub      []byte `json:"enc_pub"`
	IsBot       bool   `json:"is_bot,omitempty"`
}

type conversationView struct {
	ID               string       `json:"id"`
	Kind             string       `json:"kind"`
	CreatedBy        string       `json:"created_by"`
	CreatedAt        int64        `json:"created_at"`
	LastSeq          int64        `json:"last_seq"`
	ReadSeq          int64        `json:"read_seq"`
	JoinedSeq        int64        `json:"joined_seq"`
	Role             string       `json:"role"`
	RetentionSeconds int64        `json:"retention_seconds"`
	Members          []memberView `json:"members"`
}

func toConversationView(c *store.ConversationWithMembers) conversationView {
	v := conversationView{
		ID: c.ID, Kind: c.Kind, CreatedBy: c.CreatedBy, CreatedAt: c.CreatedAt, LastSeq: c.LastSeq,
		ReadSeq: c.Me.ReadSeq, JoinedSeq: c.Me.JoinedSeq, Role: c.Me.Role, RetentionSeconds: c.RetentionSeconds,
		Members: make([]memberView, 0, len(c.Members)),
	}
	for _, m := range c.Members {
		v.Members = append(v.Members, memberView{ID: m.AccountID, Username: m.Username, DisplayName: m.DisplayName, Role: m.Role, JoinedSeq: m.JoinedSeq, SignPub: m.SignPub, EncPub: m.EncPub, IsBot: m.IsBot})
	}
	return v
}

// eventPayload is the "event" frame: server-side facts clients react to by
// refetching the conversation.
type eventPayload struct {
	Kind    string `json:"kind"`
	ConvID  string `json:"conv_id,omitempty"`
	Actor   string `json:"actor,omitempty"`
	Account string `json:"account,omitempty"`
	Seq     int64  `json:"seq,omitempty"`
}

func (s *Server) notify(accounts []string, ev eventPayload) {
	s.hub.SendToAccounts(accounts, ws.NewFrame("event", ev))
}

func convIDParam(r *http.Request) (string, error) {
	id, err := e2e.ParseID(r.PathValue("id"))
	if err != nil {
		return "", notFound("not_found", "no such conversation")
	}
	return id.String(), nil
}

func memberIDs(c *store.ConversationWithMembers) []string {
	ids := make([]string, 0, len(c.Members))
	for _, m := range c.Members {
		ids = append(ids, m.AccountID)
	}
	return ids
}

func (s *Server) listConversations(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	convs, err := s.store.ConversationsForAccount(r.Context(), p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	views := make([]conversationView, 0, len(convs))
	for i := range convs {
		views = append(views, toConversationView(&convs[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"conversations": views})
}

type createConversationRequest struct {
	Kind      string   `json:"kind"`
	AccountID string   `json:"account_id"`
	MemberIDs []string `json:"member_ids"`
}

func (s *Server) createConversation(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	var req createConversationRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	now := time.Now().Unix()
	switch req.Kind {
	case "direct":
		if req.AccountID == "" || req.AccountID == p.AccountID {
			writeError(w, s.log, badRequest("invalid_request", "account_id must identify another user"))
			return
		}
		other, err := s.store.AccountByID(r.Context(), req.AccountID)
		if errors.Is(err, store.ErrNotFound) || (err == nil && other.Disabled) {
			writeError(w, s.log, notFound("user_not_found", "no such user"))
			return
		}
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		id, created, err := s.store.CreateDirect(r.Context(), newID(), p.AccountID, other.ID, now)
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		conv, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID)
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		status := http.StatusOK
		if created {
			status = http.StatusCreated
			s.notify([]string{p.AccountID, other.ID}, eventPayload{Kind: "conv.updated", ConvID: id, Actor: p.AccountID})
			if other.IsBot {
				s.bots.onJoined(r.Context(), other.ID, conv, p)
			}
		}
		writeJSON(w, status, toConversationView(conv))
	case "group":
		if p.IsBot {
			writeError(w, s.log, forbidden("humans_only", "bots cannot create groups"))
			return
		}
		ids := make([]string, 0, len(req.MemberIDs))
		seen := map[string]bool{p.AccountID: true}
		for _, id := range req.MemberIDs {
			if !seen[id] {
				seen[id] = true
				ids = append(ids, id)
			}
		}
		if len(ids)+1 > s.settings.Get().MaxGroupMembers {
			writeError(w, s.log, badRequest("too_many_members", "the group would exceed the member limit"))
			return
		}
		var bots []string
		if len(ids) > 0 {
			accts, err := s.store.AccountsByIDs(r.Context(), ids)
			if err != nil {
				writeError(w, s.log, err)
				return
			}
			if len(accts) != len(ids) {
				writeError(w, s.log, notFound("user_not_found", "one of the members does not exist"))
				return
			}
			for _, a := range accts {
				if a.IsBot {
					bots = append(bots, a.ID)
				}
				// The same rule as addMember: this branch never calls it, and
				// without the check here the refusal is one request away from
				// being bypassed by starting a new group instead.
				if err := s.mayAddToGroup(r, p.AccountID, &a); err != nil {
					writeError(w, s.log, err)
					return
				}
			}
		}
		id := newID()
		if err := s.store.CreateGroup(r.Context(), id, p.AccountID, ids, now); err != nil {
			writeError(w, s.log, err)
			return
		}
		conv, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID)
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		s.notify(memberIDs(conv), eventPayload{Kind: "conv.updated", ConvID: id, Actor: p.AccountID})
		for _, b := range bots {
			s.bots.onJoined(r.Context(), b, conv, p)
		}
		writeJSON(w, http.StatusCreated, toConversationView(conv))
	default:
		writeError(w, s.log, badRequest("invalid_kind", "kind must be direct or group"))
	}
}

func (s *Server) getConversation(w http.ResponseWriter, r *http.Request) {
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
	writeJSON(w, http.StatusOK, toConversationView(conv))
}

type memberRequest struct {
	AccountID string `json:"account_id"`
}

// mayAddToGroup enforces the target's own "anybody may add me to a group"
// setting: with it off, only somebody it has already talked to may, and
// "talked to" means a shared conversation that carried at least one message —
// an empty direct conversation can be created with anyone in one request and
// so proves nothing.
//
// Bots have no such setting: they exist to be put in conversations. The
// account adding itself (a group it creates) is never refused.
func (s *Server) mayAddToGroup(r *http.Request, actor string, target *store.Account) error {
	if target.AllowGroupAdd || target.IsBot || target.ID == actor {
		return nil
	}
	known, err := s.store.SharesConversation(r.Context(), actor, target.ID)
	if err != nil {
		return err
	}
	if !known {
		return forbidden("group_add_refused", "this user only accepts group invitations from people they have talked to")
	}
	return nil
}

func (s *Server) addMember(w http.ResponseWriter, r *http.Request) {
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
	if conv.Kind != "group" {
		writeError(w, s.log, badRequest("not_a_group", "members can only be added to groups"))
		return
	}
	if conv.Me.Role != "owner" {
		writeError(w, s.log, forbidden("not_owner", "only the group owner can add members"))
		return
	}
	var req memberRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	acct, err := s.store.AccountByID(r.Context(), req.AccountID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && acct.Disabled) {
		writeError(w, s.log, notFound("user_not_found", "no such user"))
		return
	}
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if len(conv.Members)+1 > s.settings.Get().MaxGroupMembers {
		writeError(w, s.log, badRequest("too_many_members", "the group would exceed the member limit"))
		return
	}
	if err := s.mayAddToGroup(r, p.AccountID, acct); err != nil {
		writeError(w, s.log, err)
		return
	}
	if err := s.store.AddMember(r.Context(), id, acct.ID); err != nil {
		if errors.Is(err, store.ErrConflict) {
			writeError(w, s.log, conflict("already_member", "this user is already a member"))
			return
		}
		writeError(w, s.log, err)
		return
	}
	updated, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	s.notify(memberIDs(updated), eventPayload{Kind: "member.added", ConvID: id, Actor: p.AccountID, Account: acct.ID})
	if acct.IsBot {
		s.bots.onJoined(r.Context(), acct.ID, updated, p)
	}
	writeJSON(w, http.StatusOK, toConversationView(updated))
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	targetID, err := e2e.ParseID(r.PathValue("account"))
	if err != nil {
		writeError(w, s.log, notFound("not_a_member", "no such member"))
		return
	}
	target := targetID.String()
	conv, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if conv.Kind != "group" {
		writeError(w, s.log, badRequest("not_a_group", "direct conversations cannot be left"))
		return
	}
	if target != p.AccountID && conv.Me.Role != "owner" {
		writeError(w, s.log, forbidden("not_owner", "only the group owner can remove members"))
		return
	}
	if err := s.store.RemoveMember(r.Context(), id, target); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, s.log, notFound("not_a_member", "no such member"))
			return
		}
		writeError(w, s.log, err)
		return
	}
	remaining := make([]string, 0, len(conv.Members))
	for _, m := range conv.Members {
		if m.AccountID != target {
			remaining = append(remaining, m.AccountID)
		}
	}
	s.notify(remaining, eventPayload{Kind: "member.removed", ConvID: id, Actor: p.AccountID, Account: target})
	s.notify([]string{target}, eventPayload{Kind: "conv.removed", ConvID: id, Actor: p.AccountID})
	w.WriteHeader(http.StatusNoContent)
}

type readRequest struct {
	Seq int64 `json:"seq"`
}

func (s *Server) markRead(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	var req readRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	if req.Seq < 0 {
		writeError(w, s.log, badRequest("invalid_request", "seq must be non-negative"))
		return
	}
	if err := s.store.MarkRead(r.Context(), id, p.AccountID, req.Seq); err != nil {
		writeError(w, s.log, err)
		return
	}
	s.hub.SendToAccount(p.AccountID, ws.NewFrame("event", eventPayload{Kind: "read.updated", ConvID: id, Seq: req.Seq, Actor: p.DeviceID}))
	w.WriteHeader(http.StatusNoContent)
}

type retentionRequest struct {
	Seconds int64 `json:"seconds"`
}

const maxRetentionSeconds = 365 * 24 * 3600

// setRetention configures disappearing messages: any member of a direct
// conversation, or the owner of a group, may change the timer. The server
// enforces it by purging stored ciphertext; clients purge their local copies.
func (s *Server) setRetention(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	var req retentionRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	if req.Seconds < 0 || req.Seconds > maxRetentionSeconds || (req.Seconds > 0 && req.Seconds < 60) {
		writeError(w, s.log, badRequest("invalid_retention", "seconds must be 0 (off) or between 60 and one year"))
		return
	}
	conv, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if conv.Kind == "group" && conv.Me.Role != "owner" {
		writeError(w, s.log, forbidden("not_owner", "only the group owner can change the timer"))
		return
	}
	if err := s.store.SetRetention(r.Context(), id, req.Seconds); err != nil {
		writeError(w, s.log, err)
		return
	}
	s.notify(memberIDs(conv), eventPayload{Kind: "conv.updated", ConvID: id, Actor: p.AccountID})
	w.WriteHeader(http.StatusNoContent)
}
