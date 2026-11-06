package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type vault struct {
	Slot    string
	Members map[string]string
	Revoked map[string]bool
}

func loadState(path string) (map[string]vault, error) {
	state := map[string]vault{}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read registry: %w", err)
	}
	if err = json.Unmarshal(b, &state); err != nil || state == nil {
		return nil, fmt.Errorf("invalid registry")
	}
	return state, nil
}
func memberID(key string) string {
	raw, err := base64.StdEncoding.DecodeString(key)
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(raw)
	return base64.RawURLEncoding.EncodeToString(hash[:])
}
func reserve(root, origin string, e enrollment) (vault, error) {
	path := filepath.Join(root, "registry.json")
	state, err := loadState(path)
	if err != nil {
		return vault{}, err
	}
	v, exists := state[e.Folder]
	if v.Revoked[memberID(e.PublicKey)] {
		return vault{}, denied
	}
	if target, ok := strings.CutPrefix(e.Invite, "revoke:"); ok {
		raw, err := base64.RawURLEncoding.Strict().DecodeString(target)
		if err != nil || len(raw) != 32 || !exists || v.Members[e.PublicKey] != e.Device || target == memberID(e.PublicKey) {
			return vault{}, denied
		}
		if v.Revoked[target] {
			return v, nil
		}
		if len(v.Revoked) >= 4096 {
			return vault{}, denied
		}
		if v.Revoked == nil {
			v.Revoked = map[string]bool{}
		}
		v.Revoked[target] = true
		for key := range v.Members {
			if memberID(key) == target {
				delete(v.Members, key)
			}
		}
	} else if exists {
		if v.Members[e.PublicKey] == e.Device {
			return v, nil
		}
		for _, device := range v.Members {
			if device == e.Device {
				return vault{}, denied
			}
		}
		if !e.delegated(origin, v.Members) || v.Members[e.PublicKey] != "" || len(v.Members) >= 64 {
			return vault{}, denied
		}
	} else {
		if !tokenID.MatchString(e.Invite) {
			return vault{}, denied
		}
		hash := sha256.Sum256([]byte(e.Invite))
		slot := hex.EncodeToString(hash[:])
		ticket, err := os.Stat(filepath.Join(root, "invites", slot))
		if err != nil || !ticket.Mode().IsRegular() || time.Since(ticket.ModTime()) > 7*24*time.Hour {
			return vault{}, denied
		}
		for _, other := range state {
			if other.Slot == slot {
				return vault{}, denied
			}
		}
		v = vault{Slot: slot, Members: map[string]string{}}
	}
	v.Members[e.PublicKey] = e.Device
	state[e.Folder] = v
	b, err := json.Marshal(state)
	if err != nil {
		return vault{}, fmt.Errorf("encode registry: %w", err)
	}
	stage, err := os.CreateTemp(root, "registry-*.tmp")
	if err != nil {
		return vault{}, fmt.Errorf("stage registry: %w", err)
	}
	defer os.Remove(stage.Name())
	if _, err = stage.Write(b); err == nil {
		err = stage.Sync()
	}
	closeErr := stage.Close()
	if err != nil {
		return vault{}, fmt.Errorf("persist registry: %w", err)
	}
	if closeErr != nil {
		return vault{}, fmt.Errorf("close registry: %w", closeErr)
	}
	if err = os.Rename(stage.Name(), path); err != nil {
		return vault{}, fmt.Errorf("commit registry: %w", err)
	}
	dir, err := os.Open(root)
	if err != nil {
		return vault{}, fmt.Errorf("open registry directory: %w", err)
	}
	defer dir.Close()
	if err = dir.Sync(); err != nil {
		return vault{}, fmt.Errorf("persist registry directory: %w", err)
	}
	return v, nil
}
