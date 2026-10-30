package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFilesAndReplay(t *testing.T) {
	n, key, id := fixture(t)
	path := "ops/" + id + "/202610-0001.log"
	for _, body := range []string{"encrypted tail", "encrypted extended tail"} {
		w := httptest.NewRecorder()
		n.ServeHTTP(w, signed(t, n, key, id, "PUT", "file", path, body))
		if w.Code != http.StatusNoContent {
			t.Fatalf("put status = %d: %s", w.Code, w.Body.String())
		}
	}
	r := signed(t, n, key, id, "GET", "file", path, "")
	w := httptest.NewRecorder()
	n.ServeHTTP(w, r)
	if w.Code != 200 || w.Body.String() != "encrypted extended tail" {
		t.Fatalf("get status = %d: %s", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	n.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("replay status = %d", w.Code)
	}
}

func TestQuotaAndRestart(t *testing.T) {
	n, key, id := fixture(t)
	n.config.QuotaBytes = 5
	path := "members/" + id + ".json"
	for _, c := range []struct {
		body string
		code int
	}{{"saved", 204}, {"too large", 413}} {
		w := httptest.NewRecorder()
		n.ServeHTTP(w, signed(t, n, key, id, "PUT", "file", path, c.body))
		if w.Code != c.code {
			t.Fatalf("quota status = %d", w.Code)
		}
	}
	reopened, err := newNode(n.config, n.root.Name())
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() {
		if err := reopened.root.Close(); err != nil {
			t.Errorf("close reopened root: %v", err)
		}
	}()
	w := httptest.NewRecorder()
	reopened.ServeHTTP(w, signed(t, reopened, key, id, "GET", "file", path, ""))
	if w.Code != 200 || w.Body.String() != "saved" {
		t.Fatalf("persisted data changed: %d %q", w.Code, w.Body.String())
	}
}
