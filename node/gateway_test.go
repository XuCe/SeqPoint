package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestGatewayInvitationIsolation(t *testing.T) {
	root := t.TempDir()
	origin := "https://gw.test"
	g, err := openGateway(root, origin)
	if err != nil {
		t.Fatal(err)
	}
	mint := func() string {
		link, err := g.manage(url.Values{"action": {"invite"}})
		if err != nil {
			t.Fatal(err)
		}
		return strings.Split(link, "#gw.")[1]
	}
	token := mint()
	identity := func(seed byte, vault string) (gatewayClaim, ed25519.PrivateKey) {
		key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, 32))
		pub := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
		id, _ := gatewayKey(pub)
		return gatewayClaim{Folder: vault, Device: id, PublicKey: pub, Invite: token}, key
	}
	owner, priv := identity(1, strings.Repeat("a", 43))
	other, _ := identity(2, strings.Repeat("b", 43))
	results := make(chan error, 2)
	for _, claim := range []gatewayClaim{owner, other} {
		go func() { results <- g.claim(claim) }()
	}
	first, second := <-results, <-results
	if (first == nil) == (second == nil) {
		t.Fatal("one invite opened multiple vaults", first, second)
	}
	if g.nodes[owner.Folder] == nil {
		owner.Invite = mint()
		if err = g.claim(owner); err != nil {
			t.Fatal(err)
		}
	}
	g.close()
	g, err = openGateway(root, origin)
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	if err = g.claim(owner); err != nil {
		t.Fatal("owner retry", err)
	}
	guest, _ := identity(3, owner.Folder)
	guest.Issuer = owner.PublicKey
	guest.Grant = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(strings.Join([]string{"seqpoint-gateway-grant-v1", origin, owner.Folder, guest.PublicKey}, "\n"))))
	if err = g.claim(guest); err != nil {
		t.Fatal(err)
	}
	hostile := guest
	hostile.Folder = other.Folder
	hostile.Invite = ""
	if err = g.claim(hostile); err != errUnauthorized {
		t.Fatal("cross vault access", err)
	}
	owner.Invite = "revoke:" + guest.Device
	if err = g.claim(owner); err != nil {
		t.Fatal(err)
	}
	if err = g.claim(guest); err != errUnauthorized {
		t.Fatal("re-enroll revoked device", err)
	}
	r := httptest.NewRequest("GET", "/seqpoint/relay/v2/usage?vault="+owner.Folder, nil)
	r.Header.Set("X-Seqpoint-Device", guest.Device)
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("revoked transfer", w.Code)
	}
}

func TestGatewayLimitsAndAdmin(t *testing.T) {
	g, err := openGateway(t.TempDir(), "https://localhost")
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	member := func(vault string) gatewayClaim {
		link, err := g.manage(url.Values{"action": {"invite"}})
		if err != nil {
			t.Fatal(err)
		}
		_, key, id := fixture(t)
		return gatewayClaim{Folder: vault, Device: id, PublicKey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey)), Invite: strings.Split(link, "#gw.")[1]}
	}
	a := member(strings.Repeat("a", 43))
	b := member(strings.Repeat("b", 43))
	expired := member(strings.Repeat("c", 43))
	g.registry.Invites[ticketHash(expired.Invite)] = gatewayTicket{}
	if err = g.claim(expired); err != errUnauthorized {
		t.Fatal("expired ticket accepted", err)
	}
	for _, c := range []gatewayClaim{a, b} {
		if err = g.claim(c); err != nil {
			t.Fatal(err)
		}
	}
	_, err = g.manage(url.Values{"action": {"update"}, "quota": {"1"}, "vault": {a.Folder}})
	if err != nil {
		t.Fatal(err)
	}
	path := "members/" + a.Device + ".json"
	payload := make([]byte, 1<<20+1)
	if code, _ := g.nodes[a.Folder].file("PUT", path, []byte("old")); code != 204 {
		t.Fatal(code)
	}
	if code, _ := g.nodes[a.Folder].file("PUT", path, payload); code != 413 {
		t.Fatal("quota missing", code)
	}
	if code, data := g.nodes[a.Folder].file("GET", path, nil); code != 200 || string(data) != "old" {
		t.Fatal("read damaged after quota rejection")
	}
	if code, _ := g.nodes[b.Folder].file("PUT", path, payload); code != 204 {
		t.Fatal("other vault blocked", code)
	}
	_, err = g.manage(url.Values{"action": {"update"}, "quota": {"1"}, "vault": {a.Folder}, "paused": {"on"}})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/seqpoint/relay/v2/usage?vault="+a.Folder, nil)
	r.Header.Set("X-Seqpoint-Device", a.Device)
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
	admin := g.admin("test-password")
	q := httptest.NewRequest("POST", "/", strings.NewReader("action=invite"))
	w = httptest.NewRecorder()
	admin.ServeHTTP(w, q)
	if w.Code != 401 {
		t.Fatal("admin requires credentials")
	}
	q.SetBasicAuth("admin", "test-password")
	q.Header.Set("Sec-Fetch-Site", "cross-site")
	w = httptest.NewRecorder()
	admin.ServeHTTP(w, q)
	if w.Code != 403 {
		t.Fatal("cross-site action accepted")
	}
}
