package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestContentGCGraceAndMediaRetention(t *testing.T) {
	n, key, id := fixture(t)
	now := time.Now()
	paths := []string{}
	for i := 0; i < 3; i++ {
		data := []byte(fmt.Sprintf("chunk-%d", i))
		hash := fmt.Sprintf("%x", sha256.Sum256(data))
		path := "blobs/" + id + "/" + hash + ".bin"
		paths = append(paths, path)
		if err := n.atomicWrite(path, data); err != nil {
			t.Fatal(err)
		}
		if i != 1 {
			if err := os.Chtimes(filepath.Join(n.root.Name(), path), now.Add(-25*time.Hour), now.Add(-25*time.Hour)); err != nil {
				t.Fatal(err)
			}
		}
	}
	hash := filepath.Base(paths[2])[:64]
	h := contentManifest{Version: 2, Kind: "media", Vault: n.config.VaultID, Writer: id, Author: id, Epoch: 1,
		Subject: "media", Anchor: fmt.Sprintf("%064d", 0), Membership: id, Chunks: []string{hash}}
	manifest := encodeTestJSON(t, signedTestEnvelope(t, key, h))
	path := fmt.Sprintf("manifests/%s/%x.json", id, sha256.Sum256(manifest))
	if code, _ := n.file("PUT", path, manifest); code != 204 {
		t.Fatalf("media %d", code)
	}
	if err := n.reclaimContent(now); err != nil {
		t.Fatal(err)
	}
	if _, err := n.root.Stat(paths[0]); !os.IsNotExist(err) {
		t.Fatal("stale orphan retained")
	}
	for _, path := range paths[1:] {
		if _, err := n.root.Stat(path); err != nil {
			t.Fatal("live or staged chunk removed", err)
		}
	}
}
