package main

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/http/httptest"
	"os"
	"testing"
)

func TestCheckpointCASAndRecovery(t *testing.T) {
	n, key, id := fixture(t)
	data, name := checkpointTestData(t, n, key, id, 1)
	request := func(previous string, data []byte, name string) []byte {
		return encodeTestJSON(t, map[string]string{
			"previous": previous, "manifest": base64.RawURLEncoding.EncodeToString(data), "segment": name})
	}
	if code, _ := n.route("POST", "checkpoint", id, id, request("wrong", data, name)); code != 409 {
		t.Fatalf("CAS %d", code)
	}
	if _, err := n.root.Stat("ops/" + id + "/" + name); err != nil {
		t.Fatal("premature GC", err)
	}
	if code, _ := n.route("POST", "checkpoint", id, id, request("", data, name)); code != 200 {
		t.Fatalf("commit %d", code)
	}
	if _, err := n.root.Stat("ops/" + id + "/" + name); !os.IsNotExist(err) {
		t.Fatalf("not reclaimed %v", err)
	}
	if code, _ := n.route("POST", "checkpoint", id, id, request("", data, name)); code != 200 {
		t.Fatalf("retry %d", code)
	}
	w := httptest.NewRecorder()
	n.ServeHTTP(w, signed(t, n, key, id, "GET", "usage", "", ""))
	if w.Code != 426 {
		t.Fatalf("legacy barrier %d", w.Code)
	}
	second, secondName := checkpointTestData(t, n, key, id, 2)
	firstHash := fmt.Sprintf("%x", sha256.Sum256(data))
	if code, _ := n.route("POST", "checkpoint", id, id, request(firstHash, second, secondName)); code != 200 {
		t.Fatalf("advance %d", code)
	}
	if code, _ := n.route("POST", "checkpoint", id, id, request(fmt.Sprintf("%x", sha256.Sum256(second)), data, name)); code != 409 {
		t.Fatalf("rollback %d", code)
	}
}
