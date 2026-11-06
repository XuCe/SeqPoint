package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsolation(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key := base64.StdEncoding.EncodeToString(pub)
	root := t.TempDir()
	origin := "https://example.test"
	token := strings.Repeat("a", 64)
	if err = os.Mkdir(filepath.Join(root, "invites"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(root, "invites", fmt.Sprintf("%x", sha256.Sum256([]byte(token)))), nil, 0600); err != nil {
		t.Fatal(err)
	}
	e := enrollment{Folder: "seqpoint-" + strings.Repeat("b", 64), Invite: token, PublicKey: key, Device: "AAAAAAA" + strings.Repeat("-AAAAAAA", 7)}
	sign := func(fields ...string) string {
		return base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(strings.Join(fields, "\n"))))
	}
	e.Signature = sign("seqpoint-enroll-v1", origin, e.Folder, e.Device, key, token, "", "")
	if !e.valid(origin) || e.valid(origin+"x") {
		t.Fatal("signature scope")
	}
	for i := 0; i < 2; i++ {
		if _, err = reserve(root, origin, e); err != nil {
			t.Fatal(err)
		}
	}
	other := e
	other.Folder = "seqpoint-" + strings.Repeat("c", 64)
	if _, err = reserve(root, origin, other); err != denied {
		t.Fatal("reused invitation")
	}
	other = e
	other.PublicKey = base64.StdEncoding.EncodeToString(make([]byte, 32))
	other.Device = strings.ReplaceAll(e.Device, "A", "B")
	if _, err = reserve(root, origin, other); err != denied {
		t.Fatal("replaced owner")
	}
	other.Issuer = key
	other.Grant = sign("seqpoint-grant-v1", origin, e.Folder, other.PublicKey)
	if _, err = reserve(root, origin, other); err != nil {
		t.Fatal(err)
	}
	revoke := e
	revoke.Invite = "revoke:" + memberID(other.PublicKey)
	for range 2 {
		if _, err = reserve(root, origin, revoke); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = reserve(root, origin, other); err != denied {
		t.Fatal("revoked device rejoined")
	}
	other.PublicKey = "third"
	if _, err = reserve(root, origin, other); err != denied {
		t.Fatal("replayed delegation")
	}
}
