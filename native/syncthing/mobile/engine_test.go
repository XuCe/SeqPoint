package mobile

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestEngineLifecycle(t *testing.T) {
	home, address, key := t.TempDir(), freeAddress(t), strings.Repeat("a", 32)
	if err := Start(home, address, key); err != nil {
		t.Fatalf("start engine: %v", err)
	}
	t.Cleanup(func() {
		if err := Stop(); err != nil {
			t.Errorf("stop engine: %v", err)
		}
	})
	id := statusID(t, address, key)
	client := &http.Client{Timeout: time.Second}
	response, err := client.Get("http://" + address + "/rest/system/status")
	if err != nil {
		t.Fatalf("check REST authentication: %v", err)
	}
	if err := response.Body.Close(); err != nil {
		t.Fatalf("close unauthorized response: %v", err)
	}
	if response.StatusCode != http.StatusForbidden && response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("REST without key returned %d", response.StatusCode)
	}
	if err := Start(home, address, key); err == nil {
		t.Fatal("duplicate start must fail")
	}
	if err := Stop(); err != nil {
		t.Fatalf("stop first engine: %v", err)
	}
	if err := Start(home, address, key); err != nil {
		t.Fatalf("restart engine: %v", err)
	}
	if next := statusID(t, address, key); next != id {
		t.Fatal("engine identity changed after restart")
	}
}

func TestDamagedIdentityDoesNotRegenerate(t *testing.T) {
	home, address, key := t.TempDir(), freeAddress(t), strings.Repeat("a", 32)
	if err := Start(home, address, key); err != nil {
		t.Fatalf("start engine: %v", err)
	}
	if err := Stop(); err != nil {
		t.Fatalf("stop engine: %v", err)
	}
	path := filepath.Join(home, "cert.pem")
	if err := os.WriteFile(path, []byte("damaged"), 0600); err != nil {
		t.Fatalf("damage test certificate: %v", err)
	}
	if err := Start(home, address, key); err == nil {
		t.Fatal("damaged identity must fail")
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read damaged certificate: %v", err)
	}
	if string(bytes) != "damaged" {
		t.Fatal("existing identity was replaced")
	}
}

func TestRejectsEnvironmentOverride(t *testing.T) {
	t.Setenv("STGUIADDRESS", "0.0.0.0:8384")
	if err := Start(t.TempDir(), freeAddress(t), strings.Repeat("a", 32)); err == nil {
		t.Fatal("environment override must not expose management API")
	}
}

func TestMissingIdentityDoesNotResetConfiguredEngine(t *testing.T) {
	home, address, key := t.TempDir(), freeAddress(t), strings.Repeat("a", 32)
	if err := Start(home, address, key); err != nil {
		t.Fatalf("start engine: %v", err)
	}
	if err := Stop(); err != nil {
		t.Fatalf("stop engine: %v", err)
	}
	for _, name := range []string{"cert.pem", "key.pem"} {
		if err := os.Remove(filepath.Join(home, name)); err != nil {
			t.Fatalf("remove test identity: %v", err)
		}
	}
	err := Start(home, address, key)
	if err == nil {
		if stopErr := Stop(); stopErr != nil {
			t.Fatalf("stop unexpected engine: %v", stopErr)
		}
		t.Fatal("existing config must not silently get a new identity")
	}
	if _, err := os.Stat(filepath.Join(home, "cert.pem")); !os.IsNotExist(err) {
		t.Fatalf("missing certificate was regenerated: %v", err)
	}
}

func TestRejectsExposedManagementInterface(t *testing.T) {
	for _, address := range []string{"0.0.0.0:8384", "example.com:8384", "127.0.0.1:0"} {
		if err := Start(t.TempDir(), address, strings.Repeat("a", 32)); err == nil {
			if err := Stop(); err != nil {
				t.Fatalf("stop invalid engine: %v", err)
			}
			t.Fatalf("accepted unsafe address %s", address)
		}
	}
}

func statusID(t *testing.T, address, key string) string {
	t.Helper()
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		request, err := http.NewRequest(http.MethodGet, "http://"+address+"/rest/system/status", nil)
		if err != nil {
			t.Fatalf("create status request: %v", err)
		}
		request.Header.Set("X-API-Key", key)
		response, err := client.Do(request)
		if err == nil {
			var status struct {
				MyID string `json:"myID"`
			}
			decodeErr := json.NewDecoder(response.Body).Decode(&status)
			closeErr := response.Body.Close()
			if closeErr != nil {
				t.Fatalf("close status response: %v", closeErr)
			}
			if response.StatusCode == 200 && decodeErr == nil && status.MyID != "" {
				return status.MyID
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("engine REST identity did not become ready")
	return ""
}

func freeAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve GUI port: %v", err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatalf("release GUI port: %v", err)
	}
	return address
}
