package main

import (
	"crypto/sha256"
	"fmt"
	"testing"
)

func TestV2ContentAddressing(t *testing.T) {
	n, _, id := fixture(t)
	body := []byte("encrypted chunk")
	path := fmt.Sprintf("blobs/%s/%x.bin", id, sha256.Sum256(body))
	if code, _ := n.route("PUT", "file", path, id, body); code != 204 {
		t.Fatalf("put: %d", code)
	}
	if code, _ := n.route("PUT", "file", path, id, []byte("changed")); code != 409 {
		t.Fatalf("hash: %d", code)
	}
	if code, data := n.route("GET", "file", path, id, nil); code != 200 || string(data) != string(body) {
		t.Fatalf("get: %d", code)
	}
	if code, _ := n.route("PUT", "file", path, "another", body); code != 403 {
		t.Fatalf("owner: %d", code)
	}
	broken := append([]byte(nil), body...)
	broken[0] ^= 1
	if err := n.atomicWrite(path, broken); err != nil {
		t.Fatal(err)
	}
	if code, _ := n.route("PUT", "file", path, id, body); code != 204 {
		t.Fatalf("repair: %d", code)
	}
	if code, data := n.route("GET", "file", path, id, nil); code != 200 || string(data) != string(body) {
		t.Fatal("same-size corruption was not repaired")
	}
}
