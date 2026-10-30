// Package mobile embeds the official Syncthing engine in mobile applications.
package mobile

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/thejerf/suture/v4"
)

var lifecycle sync.Mutex
var active *engine

func configure(home, address, key string, cert tls.Certificate, logger events.Logger,
	supervisor *suture.Supervisor) (config.Wrapper, error) {
	path := filepath.Join(home, "config.xml")
	_, statErr := os.Stat(path)
	if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect engine config: %w", statErr)
	}
	cfg, err := syncthing.LoadConfigAtStartup(path, cert, logger, false, false)
	if err != nil {
		return nil, fmt.Errorf("load engine config: %w", err)
	}
	supervisor.Add(cfg)
	waiter, err := cfg.Modify(func(c *config.Configuration) {
		if errors.Is(statErr, os.ErrNotExist) {
			c.Folders = nil
		}
		// Application credentials must select the active target before any transfer.
		for i := range c.Folders {
			c.Folders[i].Paused = true
		}
		c.GUI.Enabled = true
		c.GUI.RawAddress = address
		c.GUI.RawUseTLS = false
		c.GUI.APIKey = key
		c.Options.AutoUpgradeIntervalH = 0
		c.Options.URAccepted = -1
	})
	if err != nil {
		return nil, fmt.Errorf("configure management endpoint: %w", err)
	}
	waiter.Wait()
	if err := cfg.Save(); err != nil {
		return nil, fmt.Errorf("persist engine config: %w", err)
	}
	return cfg, nil
}

func launch(home, address, key string, cert tls.Certificate) (result *engine, err error) {
	ctx, cancel := context.WithCancel(context.Background())
	supervisor := suture.New("seqpoint-syncthing", svcutil.SpecWithDebugLogger())
	current := &engine{cancel: cancel, done: supervisor.ServeBackground(ctx)}
	defer func() {
		if err != nil {
			cancel()
			if stopErr := <-current.done; stopErr != nil && !errors.Is(stopErr, context.Canceled) {
				err = errors.Join(err, fmt.Errorf("clean up background services: %w", stopErr))
			}
		}
	}()
	logger := events.NewLogger()
	supervisor.Add(logger)
	cfg, err := configure(home, address, key, cert, logger, supervisor)
	if err != nil {
		return nil, err
	}
	database, err := syncthing.OpenDatabase(filepath.Join(home, "index-v2"), 10920*time.Hour)
	if err != nil {
		return nil, fmt.Errorf("open engine database: %w", err)
	}
	current.app, err = syncthing.New(cfg, database, logger, cert,
		syncthing.Options{NoUpgrade: true, DBMaintenanceInterval: 8 * time.Hour})
	if err != nil {
		return nil, fmt.Errorf("create engine: %w", errors.Join(err, database.Close()))
	}
	if err := current.app.Start(); err != nil {
		return nil, fmt.Errorf("start engine: %w", err)
	}
	return current, nil
}

func Start(home, address, apiKey string) error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if active != nil {
		return fmt.Errorf("engine already running")
	}
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("parse management address: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return fmt.Errorf("parse management port: %w", err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() || port < 1 || port > 65535 || len(apiKey) < 32 {
		return fmt.Errorf("management requires loopback IP, valid port and a strong API key")
	}
	if os.Getenv("STGUIADDRESS") != "" || os.Getenv("STGUIAPIKEY") != "" {
		return fmt.Errorf("management environment overrides are not allowed")
	}
	if !filepath.IsAbs(home) {
		return fmt.Errorf("engine home must be absolute")
	}
	if err := os.MkdirAll(home, 0700); err != nil {
		return fmt.Errorf("create engine home: %w", err)
	}
	if err := locations.SetBaseDir(locations.ConfigBaseDir, home); err != nil {
		return fmt.Errorf("set config home: %w", err)
	}
	if err := locations.SetBaseDir(locations.DataBaseDir, home); err != nil {
		return fmt.Errorf("set data home: %w", err)
	}
	cert, err := certificate(home)
	if err != nil {
		return err
	}
	current, err := launch(home, address, apiKey, cert)
	if err != nil {
		return err
	}
	active = current
	return nil
}

func certificate(home string) (tls.Certificate, error) {
	certPath, keyPath := filepath.Join(home, "cert.pem"), filepath.Join(home, "key.pem")
	_, certErr := os.Stat(certPath)
	_, keyErr := os.Stat(keyPath)
	if errors.Is(certErr, os.ErrNotExist) && errors.Is(keyErr, os.ErrNotExist) {
		for _, name := range []string{"config.xml", "index-v2"} {
			_, err := os.Stat(filepath.Join(home, name))
			if err == nil {
				return tls.Certificate{}, fmt.Errorf("existing engine identity is missing; restore its certificates")
			}
			if !errors.Is(err, os.ErrNotExist) {
				return tls.Certificate{}, fmt.Errorf("inspect existing engine: %w", err)
			}
		}
		cert, err := syncthing.LoadOrGenerateCertificate(certPath, keyPath)
		if err != nil {
			return tls.Certificate{}, fmt.Errorf("create engine identity: %w", err)
		}
		return cert, nil
	}
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("load existing engine identity: %w", err)
	}
	return cert, nil
}

type engine struct {
	app    *syncthing.App
	cancel context.CancelFunc
	done   <-chan error
}

func Stop() error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if active == nil {
		return nil
	}
	current := active
	status := current.app.Stop(svcutil.ExitSuccess)
	current.cancel()
	backgroundErr := <-current.done
	active = nil
	if backgroundErr != nil && !errors.Is(backgroundErr, context.Canceled) {
		return fmt.Errorf("stop background services: %w", backgroundErr)
	}
	if status != svcutil.ExitSuccess {
		return fmt.Errorf("stop engine (%v): %w", status, current.app.Error())
	}
	return nil
}
