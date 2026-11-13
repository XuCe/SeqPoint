package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestGatewayPairMailbox(t *testing.T) {
	origin := "http://gw.test"
	g, err := openGateway(t.TempDir(), origin)
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	link, err := g.manage(url.Values{"action": {"invite"}})
	if err != nil {
		t.Fatal(err)
	}
	vault := strings.Repeat("v", 43)
	member := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{1}, 32))
	outsider := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{2}, 32))
	public := func(key ed25519.PrivateKey) (string, string) {
		pub := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
		id, _ := gatewayKey(pub)
		return pub, id
	}
	pub, id := public(member)
	if err = g.claim(gatewayClaim{Folder: vault, Device: id, PublicKey: pub, Invite: strings.Split(link, "#gw.")[1]}); err != nil {
		t.Fatal(err)
	}
	session := strings.Repeat("s", 43)
	invitation := `{"type":"invitation"}`
	open := func(key ed25519.PrivateKey, session, invitation string) int {
		pub, id := public(key)
		sig := base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte(strings.Join(
			[]string{"seqpoint-gateway-pair-v1", origin, vault, id, pub, session, invitation}, "\n"))))
		body, _ := json.Marshal(pairOpen{Vault: vault, Device: id, PublicKey: pub, Session: session, Invitation: invitation, Signature: sig})
		w := httptest.NewRecorder()
		g.ServeHTTP(w, httptest.NewRequest("POST", "/v1/pair", bytes.NewReader(body)))
		return w.Code
	}
	call := func(method, path, body string) (int, string) {
		w := httptest.NewRecorder()
		g.ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(body)))
		return w.Code, w.Body.String()
	}
	if code := open(outsider, session, invitation); code != 403 {
		t.Fatal("non-member opened a mailbox", code)
	}
	if code, _ := call("PUT", "/v1/pair/"+session+"/response", `{}`); code != 404 {
		t.Fatal("wrote to a missing mailbox", code)
	}
	if code := open(member, session, invitation); code != 200 {
		t.Fatal("member open", code)
	}
	if code := open(member, session, invitation); code != 200 {
		t.Fatal("open retry should be idempotent", code)
	}
	if code := open(member, session, `{"type":"other"}`); code != 409 {
		t.Fatal("open replaced the invitation", code)
	}
	if code, _ := call("PUT", "/v1/pair/"+session+"/response", `{"a":1}`); code != 200 {
		t.Fatal("guest response", code)
	}
	if code, _ := call("PUT", "/v1/pair/"+session+"/response", `{"a":1}`); code != 200 {
		t.Fatal("identical retry", code)
	}
	if code, _ := call("PUT", "/v1/pair/"+session+"/response", `{"a":2}`); code != 409 {
		t.Fatal("slot overwritten", code)
	}
	if code, _ := call("PUT", "/v1/pair/"+session+"/invitation", `{}`); code != 404 {
		t.Fatal("invitation slot writable", code)
	}
	if code, _ := call("PUT", "/v1/pair/"+session+"/grant", `not json`); code != 400 {
		t.Fatal("accepted invalid json", code)
	}
	code, body := call("GET", "/v1/pair/"+session, "")
	var slots map[string]json.RawMessage
	if code != 200 || json.Unmarshal([]byte(body), &slots) != nil ||
		string(slots["invitation"]) != invitation || string(slots["response"]) != `{"a":1}` || len(slots) != 2 {
		t.Fatal("read mailbox", code, body)
	}
	for i := 1; i < pairPerVault; i++ {
		if code := open(member, strings.Repeat(string(rune('a'+i)), 43), invitation); code != 200 {
			t.Fatal("open", i, code)
		}
	}
	if code := open(member, strings.Repeat("z", 43), invitation); code != 429 {
		t.Fatal("per-vault limit", code)
	}
	g.pairs.mu.Lock()
	for _, box := range g.pairs.boxes {
		box.expires = time.Now().Add(-time.Second)
	}
	g.pairs.mu.Unlock()
	if code, _ := call("GET", "/v1/pair/"+session, ""); code != 404 {
		t.Fatal("expired mailbox still readable", code)
	}
	owner := gatewayClaim{Folder: vault, Device: id, PublicKey: pub, Invite: "revoke:" + strings.Repeat("r", 43)}
	if err = g.claim(owner); err != nil {
		t.Fatal(err)
	}
	g.mu.Lock()
	v := g.registry.Vaults[vault]
	v.Paused = true
	g.registry.Vaults[vault] = v
	g.mu.Unlock()
	if code := open(member, strings.Repeat("p", 43), invitation); code != 403 {
		t.Fatal("paused vault opened a mailbox", code)
	}
}
