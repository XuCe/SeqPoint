package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func runGateway(directory, addr, cert, key string) error {
	origin, pass := os.Getenv("GATEWAY_ORIGIN"), os.Getenv("GATEWAY_ADMIN_PASSWORD")
	u, err := url.Parse(origin)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("set GATEWAY_ORIGIN to an HTTP or HTTPS origin, for example http://192.168.2.191:8385")
	}
	if len(pass) < 8 {
		return errors.New("set GATEWAY_ADMIN_PASSWORD to at least 8 bytes")
	}
	// Match browser and client normalization of default ports.
	defaultPort := ":443"
	if u.Scheme == "http" {
		defaultPort = ":80"
	}
	origin = u.Scheme + "://" + strings.TrimSuffix(strings.ToLower(u.Host), defaultPort)
	g, err := openGateway(directory, origin)
	if err != nil {
		return err
	}
	defer g.close()
	adminAddr := os.Getenv("GATEWAY_ADMIN_LISTEN")
	if adminAddr == "" {
		adminAddr = "127.0.0.1:8081"
	}
	public, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("public listener: %w", err)
	}
	defer public.Close()
	private, err := net.Listen("tcp", adminAddr)
	if err != nil {
		return fmt.Errorf("admin listener: %w", err)
	}
	defer private.Close()
	makeServer := func(h http.Handler) *http.Server {
		return &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	}
	api, admin := makeServer(g), makeServer(g.admin(pass))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 2)
	go func() {
		if cert != "" || key != "" {
			done <- api.ServeTLS(public, cert, key)
			return
		}
		done <- api.Serve(public)
	}()
	go func() { done <- admin.Serve(private) }()
	fmt.Printf("gateway=%s admin=%s\n", public.Addr(), private.Addr())
	select {
	case <-ctx.Done():
	case err = <-done:
	}
	timeout, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if closeErr := errors.Join(api.Shutdown(timeout), admin.Shutdown(timeout)); closeErr != nil {
		return errors.Join(closeErr, api.Close(), admin.Close())
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve gateway: %w", err)
	}
	return nil
}
