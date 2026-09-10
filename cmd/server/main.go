// Command server runs the messenger backend.
//
//	server                             start the HTTP/WebSocket server (configured by MSGR_* env vars)
//	server invite [-n 3] [-note text] [-days 7]   create invite codes and print them
//	server admin grant|revoke <username>          manage administrators
//	server admin list                             list administrators
//	server version                                print the build number
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/api"
	"github.com/william-aqn/family-messenger-e2e/internal/config"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

func main() {
	var err error
	switch {
	case len(os.Args) > 1 && (os.Args[1] == "version" || os.Args[1] == "-version" || os.Args[1] == "--version"):
		fmt.Println(api.Version)
		return
	case len(os.Args) > 1 && os.Args[1] == "invite":
		err = runInvite(os.Args[2:])
	case len(os.Args) > 1 && os.Args[1] == "admin":
		err = runAdmin(os.Args[2:])
	default:
		err = run()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func newLogger(cfg *config.Config) *slog.Logger {
	level := slog.LevelInfo
	if cfg.Debug {
		level = slog.LevelDebug
	}
	opts := &slog.HandlerOptions{Level: level}
	if cfg.LogJSON {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stdout, opts))
}

func openStore() (*config.Config, *store.Store, error) {
	cfg, err := config.FromEnv()
	if err != nil {
		return nil, nil, err
	}
	st, err := store.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("open database: %w", err)
	}
	return cfg, st, nil
}

func run() error {
	cfg, st, err := openStore()
	if err != nil {
		return err
	}
	defer st.Close()
	logger := newLogger(cfg)

	srv, err := api.New(cfg, st, logger)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	srv.StartJanitor(ctx)
	srv.StartUpdateChecker(ctx)

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", cfg.Addr, "registration", cfg.Registration, "data", cfg.DataDir, "turn", len(cfg.TURNURLs) > 0 && cfg.TURNSecret != "", "version", api.Version)
		errCh <- httpSrv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	logger.Info("shutting down")
	srv.Close()
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return httpSrv.Shutdown(sctx)
}

func runInvite(args []string) error {
	fs := flag.NewFlagSet("invite", flag.ContinueOnError)
	n := fs.Int("n", 1, "number of invite codes to create")
	note := fs.String("note", "", "note stored with the codes")
	days := fs.Int("days", 0, "expire after this many days (0 = never)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	_, st, err := openStore()
	if err != nil {
		return err
	}
	defer st.Close()
	var expires int64
	if *days > 0 {
		expires = time.Now().Add(time.Duration(*days) * 24 * time.Hour).Unix()
	}
	for i := 0; i < *n; i++ {
		code, err := store.NewInviteCode()
		if err != nil {
			return err
		}
		if err := st.CreateInvite(context.Background(), code, "", *note, expires); err != nil {
			return err
		}
		fmt.Println(code)
	}
	return nil
}

func runAdmin(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: server admin grant|revoke <username> | list")
	}
	_, st, err := openStore()
	if err != nil {
		return err
	}
	defer st.Close()
	ctx := context.Background()
	switch args[0] {
	case "grant", "revoke":
		if len(args) != 2 {
			return fmt.Errorf("usage: server admin %s <username>", args[0])
		}
		acct, err := st.AccountByUsername(ctx, args[1])
		if err != nil {
			return fmt.Errorf("user %q: %w", args[1], err)
		}
		if acct.IsBot {
			return errors.New("bots cannot be administrators")
		}
		if err := st.SetAccountFlags(ctx, acct.ID, acct.Disabled, args[0] == "grant"); err != nil {
			return err
		}
		fmt.Printf("%s: admin=%v\n", acct.Username, args[0] == "grant")
		return nil
	case "list":
		accts, err := st.ListAccounts(ctx, "", 500, 0)
		if err != nil {
			return err
		}
		for _, a := range accts {
			if a.IsAdmin {
				fmt.Println(a.Username)
			}
		}
		return nil
	default:
		return fmt.Errorf("unknown admin command %q", args[0])
	}
}
