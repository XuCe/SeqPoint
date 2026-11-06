package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"maps"
	"net/url"
	"strconv"
	"time"
)

func (g *gateway) manage(form url.Values) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.registryFailed {
		return "", fmt.Errorf("registry needs restart")
	}
	next := gatewayRegistry{maps.Clone(g.registry.Invites), maps.Clone(g.registry.Vaults)}
	switch form.Get("action") {
	case "invite":
		now := time.Now()
		for k, t := range next.Invites {
			if !t.Expires.After(now) {
				delete(next.Invites, k)
			}
		}
		if len(next.Invites) >= 1024 {
			return "", fmt.Errorf("待用邀请已满")
		}
		var secret [32]byte
		if _, err := rand.Read(secret[:]); err != nil {
			return "", fmt.Errorf("generate invite: %w", err)
		}
		token := hex.EncodeToString(secret[:])
		next.Invites[ticketHash(token)] = gatewayTicket{Expires: now.Add(7 * 24 * time.Hour)}
		if err := g.commit(next); err != nil {
			return "", err
		}
		return g.origin + "/invite#gw." + token, nil
	case "cancel":
		delete(next.Invites, form.Get("ticket"))
		return "", g.commit(next)
	case "update":
		v, ok := next.Vaults[form.Get("vault")]
		if !ok {
			return "", fmt.Errorf("未知资料库")
		}
		mib, err := strconv.ParseInt(form.Get("quota"), 10, 64)
		if err != nil || mib < 1 || mib > 1<<30 {
			return "", fmt.Errorf("配额超出范围")
		}
		v.QuotaBytes = mib << 20
		v.Paused = form.Get("paused") == "on"
		next.Vaults[v.VaultID] = v
		return "", g.saveVault(next, v)
	default:
		return "", fmt.Errorf("未知操作")
	}
}
