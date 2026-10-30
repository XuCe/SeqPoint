package mobile

import (
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func engineRequest(t *testing.T, address, key, method, path string, body map[string]any) map[string]any {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("encode config: %v", err)
	}
	request, err := http.NewRequest(method, "http://"+address+"/rest/"+path, strings.NewReader(string(encoded)))
	if err != nil {
		t.Fatalf("create config request: %v", err)
	}
	request.Header.Set("X-API-Key", key)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(request)
	if err != nil {
		t.Fatalf("send config request: %v", err)
	}
	bytes, readErr := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	closeErr := response.Body.Close()
	if readErr != nil {
		t.Fatalf("read config response: %v", readErr)
	}
	if closeErr != nil {
		t.Fatalf("close config response: %v", closeErr)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		t.Fatalf("config HTTP %d", response.StatusCode)
	}
	if len(bytes) == 0 {
		return nil
	}
	var decoded map[string]any
	if err := json.Unmarshal(bytes, &decoded); err != nil {
		t.Fatalf("decode config: %v", err)
	}
	return decoded
}

func TestRestartKeepsFoldersPausedUntilAuthorized(t *testing.T) {
	home, address, key := t.TempDir(), freeAddress(t), strings.Repeat("a", 32)
	if err := Start(home, address, key); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := Stop(); err != nil {
			t.Error(err)
		}
	})
	statusID(t, address, key)
	folder := engineRequest(t, address, key, "GET", "config/defaults/folder", nil)
	folder["id"], folder["path"], folder["paused"] = "saved", filepath.Join(home, "data"), false
	engineRequest(t, address, key, "PUT", "config/folders/saved", folder)
	if err := Stop(); err != nil {
		t.Fatal(err)
	}
	if err := Start(home, address, key); err != nil {
		t.Fatal(err)
	}
	statusID(t, address, key)
	saved := engineRequest(t, address, key, "GET", "config/folders/saved", nil)
	if saved["paused"] != true {
		t.Fatal("saved folder resumed before application authorization")
	}
}
