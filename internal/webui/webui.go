// Package webui serves the single-page web client, either embedded into the
// binary (dist/, filled by the Docker build) or from a directory on disk.
package webui

import (
	"bytes"
	"embed"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"strings"
	"time"
)

//go:embed all:dist
var dist embed.FS

const placeholder = `<!doctype html><meta charset="utf-8"><title>Family Messenger</title>
<body style="font-family:system-ui;margin:3rem"><h1>Family Messenger server is running</h1>
<p>The web client is not built into this binary. Build it with <code>npm run build</code> in <code>web/</code>
and either rebuild the server or point <code>MSGR_WEB_DIR</code> at <code>web/dist</code>.</p>
<p>API: <code>/api/v1</code>, health: <a href="/healthz">/healthz</a></p></body>`

// Handler returns the static file handler with SPA fallback. When dir is
// non-empty the files are read from it instead of the embedded build.
func Handler(dir string) http.Handler {
	var fsys fs.FS
	if dir != "" {
		fsys = os.DirFS(dir)
	} else {
		sub, err := fs.Sub(dist, "dist")
		if err != nil {
			panic(err)
		}
		fsys = sub
	}
	if _, err := fs.Stat(fsys, "index.html"); err != nil {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store")
			_, _ = w.Write([]byte(placeholder))
		})
	}
	files := http.FileServerFS(fsys)
	// index.html is served by hand: http.FileServer would redirect
	// "/index.html" to "/" and the SPA fallback would loop forever.
	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		f, err := fsys.Open("index.html")
		if err != nil {
			http.Error(w, "index.html missing", http.StatusInternalServerError)
			return
		}
		defer f.Close()
		data, err := io.ReadAll(f)
		if err != nil {
			http.Error(w, "index.html unreadable", http.StatusInternalServerError)
			return
		}
		var modTime time.Time
		if st, err := f.Stat(); err == nil {
			modTime = st.ModTime()
		}
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeContent(w, r, "index.html", modTime, bytes.NewReader(data))
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
		if p == "" || p == "index.html" {
			serveIndex(w, r)
			return
		}
		if st, err := fs.Stat(fsys, p); err == nil && !st.IsDir() {
			if strings.HasPrefix(p, "assets/") {
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			} else {
				w.Header().Set("Cache-Control", "no-cache")
			}
			r.URL.Path = "/" + p
			files.ServeHTTP(w, r)
			return
		}
		serveIndex(w, r) // SPA fallback: unknown routes render the app shell
	})
}
