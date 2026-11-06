package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"maps"
	"strings"
	"time"
)

var errUnauthorized = errors.New("invalid invitation or device")

func (g *gateway) claim(c gatewayClaim) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.registryFailed {
		return fmt.Errorf("registry needs restart")
	}
	old := g.registry
	v, exists := old.Vaults[c.Folder]
	if v.Paused || v.Revoked[c.Device] {
		return errUnauthorized
	}
	next := gatewayRegistry{Invites: maps.Clone(old.Invites), Vaults: maps.Clone(old.Vaults)}
	if target, ok := strings.CutPrefix(c.Invite, "revoke:"); ok {
		if !devicePattern.MatchString(target) || target == c.Device || v.Devices[c.Device] == "" {
			return errUnauthorized
		}
		if v.Revoked[target] {
			return nil
		}
		if len(v.Revoked) >= 4096 {
			return errUnauthorized
		}
		v.Revoked = maps.Clone(v.Revoked)
		v.Revoked[target] = true
	} else if exists {
		if v.Devices[c.Device] != "" {
			return nil
		}
		if !c.authorized(g.origin, v) || len(v.Devices) >= 256 {
			return errUnauthorized
		}
		v.Devices = maps.Clone(v.Devices)
	} else {
		hash := ticketHash(c.Invite)
		ticket, ok := old.Invites[hash]
		if len(c.Invite) != 64 || !ok || !time.Now().Before(ticket.Expires) {
			return errUnauthorized
		}
		delete(next.Invites, hash)
		v = gatewayVault{Config: Config{VaultID: c.Folder, Devices: map[string]string{}, QuotaBytes: 1 << 30}, Revoked: map[string]bool{}}
	}
	_, key := gatewayKey(c.PublicKey)
	v.Devices[c.Device] = base64.RawURLEncoding.EncodeToString(key)
	next.Vaults[c.Folder] = v
	return g.saveVault(next, v)
}
