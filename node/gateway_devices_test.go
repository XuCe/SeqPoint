package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func signedV2(t *testing.T, vault, id string, key ed25519.PrivateKey, method, action, body string) *http.Request {
	t.Helper()
	query := url.Values{"vault": {vault}, "path": {""}}
	r := httptest.NewRequest(method, "/seqpoint/relay/v2/"+action+"?"+query.Encode(), strings.NewReader(body))
	stamp := strconv.FormatInt(time.Now().Unix(), 10)
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(random)
	digest := sha256.Sum256([]byte(body))
	message := strings.Join([]string{"seqpoint-relay-v2", method, vault, id, action, "",
		hex.EncodeToString(digest[:]), stamp, nonce}, "\n")
	r.Header.Set("X-Seqpoint-Device", id)
	r.Header.Set("X-Seqpoint-Time", stamp)
	r.Header.Set("X-Seqpoint-Nonce", nonce)
	r.Header.Set("X-Seqpoint-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, []byte(message))))
	return r
}

func TestGatewayDeviceProfiles(t *testing.T) {
	root, origin := t.TempDir(), "https://gw.test"
	g, err := openGateway(root, origin)
	if err != nil {
		t.Fatal(err)
	}
	link, err := g.manage(url.Values{"action": {"invite"}})
	if err != nil {
		t.Fatal(err)
	}
	vault := strings.Repeat("a", 43)
	identity := func(seed byte) (gatewayClaim, ed25519.PrivateKey) {
		key := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, 32))
		pub := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
		id, _ := gatewayKey(pub)
		return gatewayClaim{Folder: vault, Device: id, PublicKey: pub}, key
	}
	owner, ownerKey := identity(1)
	owner.Invite = strings.Split(link, "#gw.")[1]
	if err = g.claim(owner); err != nil {
		t.Fatal(err)
	}
	guest, guestKey := identity(2)
	guest.Issuer = owner.PublicKey
	guest.Grant = base64.StdEncoding.EncodeToString(ed25519.Sign(ownerKey, []byte(strings.Join(
		[]string{"seqpoint-gateway-grant-v1", origin, vault, guest.PublicKey}, "\n"))))
	if err = g.claim(guest); err != nil {
		t.Fatal(err)
	}

	list := func(w *httptest.ResponseRecorder) map[string]gatewayDeviceView {
		t.Helper()
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		var out struct{ Devices []gatewayDeviceView }
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		views := map[string]gatewayDeviceView{}
		for _, v := range out.Devices {
			views[v.Device] = v
		}
		return views
	}
	r := signedV2(t, vault, owner.Device, ownerKey, "POST", "devices", `{"name":"家-PC"}`)
	r.RemoteAddr = "203.0.113.7:5000"
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	views := list(w)
	if len(views) != 2 || views[owner.Device].Name != "家-PC" || views[owner.Device].IP != "203.0.113.7" ||
		views[guest.Device].Name != "" {
		t.Fatalf("unexpected devices %+v", views)
	}

	// 内网反向代理转发的出口地址被采信，公网直连时伪造的转发头被忽略。
	r = signedV2(t, vault, guest.Device, guestKey, "POST", "devices", `{"name":"手机"}`)
	r.RemoteAddr = "172.18.0.2:4000"
	r.Header.Set("X-Forwarded-For", "198.51.100.9")
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if v := list(w)[guest.Device]; v.IP != "198.51.100.9" || v.Name != "手机" {
		t.Fatalf("proxied ip %+v", v)
	}
	r = signedV2(t, vault, guest.Device, guestKey, "POST", "devices", `{"name":"手机"}`)
	r.RemoteAddr = "203.0.113.50:4000"
	r.Header.Set("X-Forwarded-For", "1.1.1.1")
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if v := list(w)[guest.Device]; v.IP != "203.0.113.50" {
		t.Fatalf("spoofed ip accepted %+v", v)
	}

	for _, body := range []string{`{"name":""}`, `{"name":" x"}`, `{"name":"a\nb"}`, `{"name":"` + strings.Repeat("长", 65) + `"}`} {
		w = httptest.NewRecorder()
		g.ServeHTTP(w, signedV2(t, vault, owner.Device, ownerKey, "POST", "devices", body))
		if w.Code != 400 {
			t.Fatal("invalid name accepted", body, w.Code)
		}
	}
	// 未签名或签名对不上的请求不能改名。
	forged := signedV2(t, vault, owner.Device, guestKey, "POST", "devices", `{"name":"x"}`)
	w = httptest.NewRecorder()
	g.ServeHTTP(w, forged)
	if w.Code != 401 {
		t.Fatal("forged request", w.Code)
	}

	// 名称持久化，重启后仍在；被撤销的设备不再列出。
	g.close()
	if g, err = openGateway(root, origin); err != nil {
		t.Fatal(err)
	}
	defer g.close()
	owner.Invite = "revoke:" + guest.Device
	if err = g.claim(owner); err != nil {
		t.Fatal(err)
	}
	w = httptest.NewRecorder()
	g.ServeHTTP(w, signedV2(t, vault, owner.Device, ownerKey, "GET", "devices", ""))
	views = list(w)
	if len(views) != 1 || views[owner.Device].Name != "家-PC" || views[owner.Device].IP != "203.0.113.7" {
		t.Fatalf("after restart %+v", views)
	}
	w = httptest.NewRecorder()
	g.ServeHTTP(w, signedV2(t, vault, guest.Device, guestKey, "GET", "devices", ""))
	if w.Code != 401 {
		t.Fatal("revoked device listed", w.Code)
	}
}

func TestGatewayWhoami(t *testing.T) {
	g, err := openGateway(t.TempDir(), "https://gw.test")
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	r := httptest.NewRequest("GET", "/v1/whoami", nil)
	r.RemoteAddr = "192.168.2.5:1234"
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	var out map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || out["ip"] != "192.168.2.5" || out["region"] != "局域网" {
		t.Fatal(w.Code, w.Body.String())
	}
}

func TestFormatRegion(t *testing.T) {
	for raw, want := range map[string]string{
		"中国|浙江省|杭州市|电信|CN":                         "浙江省杭州市 · 电信",
		"中国|北京市|北京市|联通|CN":                         "北京市 · 联通",
		"中国|江苏省|南京市|0|CN":                          "江苏省南京市",
		"United States|California|0|Google LLC|US": "United States California · Google LLC",
		"中国|0|0|0|0":                               "中国",
		"0|0|0|内网IP|内网IP":                          "局域网",
		"":                                         "",
	} {
		if got := formatRegion(raw); got != want {
			t.Errorf("%q => %q, want %q", raw, got, want)
		}
	}
	if (ipRegions{}).lookup(netip.MustParseAddr("8.8.8.8")) != "" {
		t.Error("missing database must give empty region")
	}
}
