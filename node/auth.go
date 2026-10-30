package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (n *Node) signature(r *http.Request, body []byte) (string, time.Time, error) {
	device := r.Header.Get("X-Seqpoint-Device")
	stamp := r.Header.Get("X-Seqpoint-Time")
	nonce := r.Header.Get("X-Seqpoint-Nonce")
	ts, err := strconv.ParseInt(stamp, 10, 64)
	until := time.Unix(ts, 0).Add(60 * time.Second)
	key, ok := n.keys[device]
	if err != nil || !ok || r.URL.Query().Get("vault") != n.config.VaultID ||
		time.Until(until) < 0 || time.Until(until) > 120*time.Second {
		return "", until, fmt.Errorf("unauthorized device or timestamp")
	}
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(nonceBytes) != 32 {
		return "", until, fmt.Errorf("invalid nonce")
	}
	sig, err := base64.RawURLEncoding.DecodeString(r.Header.Get("X-Seqpoint-Signature"))
	digest := sha256.Sum256(body)
	action := strings.TrimPrefix(r.URL.Path, "/seqpoint/relay/v1/")
	protocol := "seqpoint-relay-v1"
	if strings.HasPrefix(r.URL.Path, "/seqpoint/relay/v2/") {
		protocol = "seqpoint-relay-v2"
		action = strings.TrimPrefix(r.URL.Path, "/seqpoint/relay/v2/")
	}
	message := strings.Join([]string{protocol, r.Method, n.config.VaultID,
		device, action, r.URL.Query().Get("path"), hex.EncodeToString(digest[:]), stamp, nonce}, "\n")
	if err != nil || !ed25519.Verify(key, []byte(message), sig) {
		return "", until, fmt.Errorf("invalid signature")
	}
	return device + ":" + nonce, until, nil
}

func (n *Node) authenticate(r *http.Request, body []byte) bool {
	key, expires, err := n.signature(r, body)
	if err != nil {
		return false
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	now := time.Now()
	for nonce, until := range n.nonces {
		if now.After(until) {
			delete(n.nonces, nonce)
		}
	}
	if _, replay := n.nonces[key]; replay || len(n.nonces) >= 4096 {
		return false
	}
	n.nonces[key] = expires
	return true
}
