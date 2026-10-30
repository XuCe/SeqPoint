package main

import (
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestSymlinkAndBodyLimit(t *testing.T) {
	n, key, id := fixture(t)
	if err := n.root.MkdirAll("members", 0700); err != nil {
		t.Fatal(err)
	}
	if err := n.root.Symlink(t.TempDir()+"/outside", "members/"+id+".json"); err != nil {
		t.Fatal(err)
	}
	request := signed(t, n, key, id, "PUT", "file", "members/"+id+".json", "private")
	response := httptest.NewRecorder()
	n.ServeHTTP(response, request)
	if response.Code != 400 {
		t.Fatalf("symlink status=%d", response.Code)
	}
	request = signed(t, n, key, id, "PUT", "file", "acks/"+id+".json", strings.Repeat("x", maxFile+1))
	response = httptest.NewRecorder()
	n.ServeHTTP(response, request)
	if response.Code != 413 {
		t.Fatalf("limit status=%d", response.Code)
	}
}

func TestStrictConfig(t *testing.T) {
	path := t.TempDir() + "/node.json"
	if err := os.WriteFile(path, []byte(`{"vaultId":"wrong","unknown":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readConfig(path); err == nil {
		t.Fatal("unknown field accepted")
	}
}
