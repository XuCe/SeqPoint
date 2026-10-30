package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) (*Node, ed25519.PrivateKey, string) {
	t.Helper()
	key := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))
	public := key.Public().(ed25519.PublicKey)
	hash := sha256.Sum256(public)
	id := base64.RawURLEncoding.EncodeToString(hash[:])
	config := Config{VaultID: strings.Repeat("v", 43), Devices: map[string]string{
		id: base64.RawURLEncoding.EncodeToString(public)}}
	node, err := newNode(config, t.TempDir())
	if err != nil {
		t.Fatalf("create fixture: %v", err)
	}
	t.Cleanup(func() {
		if err := node.root.Close(); err != nil {
			t.Errorf("close fixture: %v", err)
		}
	})
	return node, key, id
}

func signed(t *testing.T, n *Node, key ed25519.PrivateKey, id, method, action, path, body string) *http.Request {
	t.Helper()
	query := url.Values{"vault": {n.config.VaultID}, "path": {path}}
	r := httptest.NewRequest(method, "/seqpoint/relay/v1/"+action+"?"+query.Encode(), strings.NewReader(body))
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		t.Fatalf("random nonce: %v", err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(random)
	digest := sha256.Sum256([]byte(body))
	message := strings.Join([]string{"seqpoint-relay-v1", method, n.config.VaultID,
		id, action, path, hex.EncodeToString(digest[:]), stamp, nonce}, "\n")
	r.Header.Set("X-Seqpoint-Device", id)
	r.Header.Set("X-Seqpoint-Time", stamp)
	r.Header.Set("X-Seqpoint-Nonce", nonce)
	r.Header.Set("X-Seqpoint-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, []byte(message))))
	return r
}
