package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// A pairing mailbox lets a device that already belongs to a vault hand the
// vault to a new device through the gateway. The mailbox only relays messages:
// the one-time pairing secret stays in the link the user carries between the
// two devices, so the gateway can neither forge a member nor read the vault key.
const (
	pairLifetime = 10 * time.Minute
	pairBoxes    = 32
	pairPerVault = 4
	pairSlotSize = 64 << 10
)

// Each slot is written once, in protocol order: guest response, host and
// guest confirmations, the host's grant, then the guest's completion notice.
var pairSlots = map[string]bool{"response": true, "host": true, "guest": true, "grant": true, "done": true}

type pairBox struct {
	vault   string
	expires time.Time
	slots   map[string][]byte
}

type pairMailboxes struct {
	mu    sync.Mutex
	boxes map[string]*pairBox
}

type pairOpen struct{ Vault, Device, PublicKey, Session, Invitation, Signature string }

func (c pairOpen) valid(origin string) bool {
	id, key := gatewayKey(c.PublicKey)
	return devicePattern.MatchString(c.Vault) && devicePattern.MatchString(c.Session) && id != "" && id == c.Device &&
		len(c.Invitation) <= pairSlotSize && json.Valid([]byte(c.Invitation)) &&
		gatewayVerify(key, c.Signature, "seqpoint-gateway-pair-v1", origin, c.Vault, c.Device, c.PublicKey, c.Session, c.Invitation)
}

func (g *gateway) pairMember(vault, device string) bool {
	g.mu.RLock()
	defer g.mu.RUnlock()
	v, ok := g.registry.Vaults[vault]
	return ok && !g.registryFailed && !v.Paused && v.Devices[device] != "" && !v.Revoked[device]
}

// Caller holds m.mu.
func (m *pairMailboxes) prune(now time.Time) {
	for id, box := range m.boxes {
		if !now.Before(box.expires) {
			delete(m.boxes, id)
		}
	}
}

func (m *pairMailboxes) open(c pairOpen, now time.Time) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(now)
	if m.boxes == nil {
		m.boxes = map[string]*pairBox{}
	}
	if box := m.boxes[c.Session]; box != nil {
		if box.vault == c.Vault && bytes.Equal(box.slots["invitation"], []byte(c.Invitation)) {
			return http.StatusOK
		}
		return http.StatusConflict
	}
	open := 0
	for _, box := range m.boxes {
		if box.vault == c.Vault {
			open++
		}
	}
	if open >= pairPerVault {
		return http.StatusTooManyRequests
	}
	if len(m.boxes) >= pairBoxes {
		return http.StatusServiceUnavailable
	}
	m.boxes[c.Session] = &pairBox{vault: c.Vault, expires: now.Add(pairLifetime),
		slots: map[string][]byte{"invitation": []byte(c.Invitation)}}
	return http.StatusOK
}

func (m *pairMailboxes) read(id string, now time.Time) map[string]json.RawMessage {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(now)
	box := m.boxes[id]
	if box == nil {
		return nil
	}
	out := make(map[string]json.RawMessage, len(box.slots))
	for name, value := range box.slots {
		out[name] = json.RawMessage(bytes.Clone(value))
	}
	return out
}

func (m *pairMailboxes) write(id, slot string, value []byte, now time.Time) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.prune(now)
	box := m.boxes[id]
	if box == nil {
		return http.StatusNotFound
	}
	if prev, ok := box.slots[slot]; ok {
		if bytes.Equal(prev, value) {
			return http.StatusOK
		}
		return http.StatusConflict
	}
	box.slots[slot] = bytes.Clone(value)
	return http.StatusOK
}

func (g *gateway) servePair(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1/pair"), "/")
	switch {
	case r.Method == "POST" && len(parts) == 1 && parts[0] == "":
		var c pairOpen
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, pairSlotSize+4096)).Decode(&c); err != nil || !c.valid(g.origin) {
			http.Error(w, "invalid proof", http.StatusUnauthorized)
			return
		}
		if !g.pairMember(c.Vault, c.Device) {
			http.Error(w, "denied", http.StatusForbidden)
			return
		}
		if status := g.pairs.open(c, now); status != http.StatusOK {
			http.Error(w, http.StatusText(status), status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true}`)
	case r.Method == "GET" && len(parts) == 2 && parts[0] == "" && devicePattern.MatchString(parts[1]):
		slots := g.pairs.read(parts[1], now)
		if slots == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(slots)
	case r.Method == "PUT" && len(parts) == 3 && parts[0] == "" && devicePattern.MatchString(parts[1]) && pairSlots[parts[2]]:
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, pairSlotSize))
		if err != nil {
			http.Error(w, "body limit", http.StatusRequestEntityTooLarge)
			return
		}
		if !json.Valid(body) {
			http.Error(w, "invalid message", http.StatusBadRequest)
			return
		}
		if status := g.pairs.write(parts[1], parts[2], body, now); status != http.StatusOK {
			http.Error(w, http.StatusText(status), status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true}`)
	default:
		http.NotFound(w, r)
	}
}
