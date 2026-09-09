package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/google/uuid"
	"github.com/william-aqn/family-messenger-e2e/internal/auth"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

const maxBodyBytes = 256 << 10

// apiError is an error with an HTTP status and a machine-readable code.
type apiError struct {
	Status  int
	Code    string
	Message string
}

func (e *apiError) Error() string { return e.Code + ": " + e.Message }

func badRequest(code, msg string) *apiError { return &apiError{http.StatusBadRequest, code, msg} }
func forbidden(code, msg string) *apiError  { return &apiError{http.StatusForbidden, code, msg} }
func notFound(code, msg string) *apiError   { return &apiError{http.StatusNotFound, code, msg} }
func conflict(code, msg string) *apiError   { return &apiError{http.StatusConflict, code, msg} }

var errUnauthorized = &apiError{http.StatusUnauthorized, "unauthorized", "authentication required"}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func toAPIError(err error) *apiError {
	var ae *apiError
	if errors.As(err, &ae) {
		return ae
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return notFound("not_found", "not found")
	case errors.Is(err, store.ErrNotMember):
		return forbidden("not_a_member", "you are not a member of this conversation")
	case errors.Is(err, store.ErrRecipient):
		return badRequest("recipient_not_member", "a recipient is not a member of this conversation")
	case errors.Is(err, store.ErrConflict):
		return conflict("conflict", "already exists")
	case errors.Is(err, store.ErrConvMismatch):
		return conflict("client_id_reused", "client message id was already used in another conversation")
	case errors.Is(err, store.ErrInvite):
		return forbidden("invalid_invite", "invalid or already used invite code")
	case errors.Is(err, auth.ErrUnauthorized):
		return errUnauthorized
	}
	return nil
}

func writeError(w http.ResponseWriter, log *slog.Logger, err error) {
	ae := toAPIError(err)
	if ae == nil {
		log.Error("internal error", "err", err)
		ae = &apiError{http.StatusInternalServerError, "internal", "internal error"}
	}
	var body errorBody
	body.Error.Code = ae.Code
	body.Error.Message = ae.Message
	writeJSON(w, ae.Status, body)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			return &apiError{http.StatusRequestEntityTooLarge, "too_large", "request body too large"}
		}
		return badRequest("invalid_json", fmt.Sprintf("invalid JSON body: %v", err))
	}
	return nil
}

func principal(r *http.Request) *auth.Principal {
	p, ok := auth.FromContext(r.Context())
	if !ok {
		panic("handler registered without auth middleware")
	}
	return p
}

func newID() string {
	id, err := uuid.NewV7()
	if err != nil {
		panic(err)
	}
	return id.String()
}
