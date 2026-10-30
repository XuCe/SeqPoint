package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func run() error {
	configPath := flag.String("config", "/config/node.json", "public device allowlist")
	dataPath := flag.String("data", "/data", "persistent directory")
	address := flag.String("listen", ":8080", "listen address")
	cert := flag.String("tls-cert", "", "optional TLS certificate")
	key := flag.String("tls-key", "", "optional TLS key")
	flag.Parse()
	config, err := readConfig(*configPath)
	if err != nil {
		return err
	}
	if !devicePattern.MatchString(config.VaultID) {
		return fmt.Errorf("invalid vaultId")
	}
	node, err := newNode(config, filepath.Join(*dataPath, config.VaultID))
	if err != nil {
		return err
	}
	defer func() {
		if err := node.root.Close(); err != nil {
			log.Printf("close data root: %v", err)
		}
	}()
	listener, err := net.Listen("tcp", *address)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	server := &http.Server{Handler: node, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() {
		if *cert != "" || *key != "" {
			done <- server.ServeTLS(listener, *cert, *key)
		} else {
			done <- server.Serve(listener)
		}
	}()
	var reportErr error
	if _, err := fmt.Fprintln(os.Stdout, "listening="+listener.Addr().String()); err != nil {
		reportErr = fmt.Errorf("report listener: %w", err)
		stop()
	}
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve: %w", err)
		}
	case <-ctx.Done():
		timeout, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(timeout); err != nil {
			return errors.Join(fmt.Errorf("shutdown: %w", err), server.Close())
		}
		if err := <-done; !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("stop server: %w", err)
		}
	}
	return reportErr
}
