package api

import (
	"net/http"
	"strconv"
	"strings"
)

// listUsers lets members discover each other (prefix search, or the whole
// list for an empty query) while the administrator keeps the user directory
// enabled. Exact lookups by username (getUser) work regardless.
func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	if !s.settings.Get().UserDirectory {
		writeError(w, s.log, forbidden("directory_disabled", "the user directory is disabled on this server"))
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	prefix := strings.TrimPrefix(strings.TrimSpace(r.URL.Query().Get("q")), "@")
	users, err := s.store.Directory(r.Context(), prefix, limit)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}
