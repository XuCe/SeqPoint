package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

var devicePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

func newNode(config Config, directory string) (*Node, error) {
	if !devicePattern.MatchString(config.VaultID) || len(config.Devices) == 0 {
		return nil, fmt.Errorf("vaultId and devices are required")
	}
	keys := make(map[string]ed25519.PublicKey)
	for id, encoded := range config.Devices {
		key, err := base64.RawURLEncoding.DecodeString(encoded)
		fingerprint := sha256.Sum256(key)
		if err != nil || len(key) != ed25519.PublicKeySize ||
			base64.RawURLEncoding.EncodeToString(fingerprint[:]) != id {
			return nil, fmt.Errorf("invalid device public key")
		}
		keys[id] = ed25519.PublicKey(key)
	}
	if config.QuotaBytes == 0 {
		config.QuotaBytes = 1 << 30
	}
	if config.QuotaBytes < 1 {
		return nil, fmt.Errorf("quotaBytes must be positive")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, fmt.Errorf("create data root: %w", err)
	}
	parent, err := os.Open(filepath.Dir(directory))
	if err != nil {
		return nil, fmt.Errorf("open data parent: %w", err)
	}
	if err := errors.Join(parent.Sync(), parent.Close()); err != nil {
		return nil, fmt.Errorf("persist data parent: %w", err)
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, fmt.Errorf("open data root: %w", err)
	}
	return &Node{config: config, keys: keys, root: root,
		nonces: make(map[string]time.Time), requests: make(chan struct{}, 8)}, nil
}
