package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"testing"
)

func encodeTestJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func signedTestEnvelope(t *testing.T, key ed25519.PrivateKey, value any) signedEnvelope {
	t.Helper()
	payload := encodeTestJSON(t, value)
	return signedEnvelope{Payload: base64.RawURLEncoding.EncodeToString(payload), Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, payload))}
}
func checkpointTestData(t *testing.T, n *Node, key ed25519.PrivateKey, id string, seq int64) ([]byte, string) {
	t.Helper()
	segment := append(encodeTestJSON(t, map[string]any{"device_id": id, "seq": seq, "sealed": true}), []byte("\nciphertext")...)
	name := fmt.Sprintf("202610-%04d.log", seq)
	if err := n.atomicWrite("ops/"+id+"/"+name, segment); err != nil {
		t.Fatal(err)
	}
	anchor := fmt.Sprintf("%x", sha256.Sum256(segment))
	proof := signedTestEnvelope(t, key, map[string]any{"domain": "seqpoint-checkpoint-v2", "vault": n.config.VaultID, "author": id, "sequence": seq, "anchor": anchor})
	h := contentManifest{Version: 2, Kind: "checkpoint", Vault: n.config.VaultID, Writer: id, Author: id, Subject: id,
		Epoch: 1, Sequence: seq, Anchor: anchor, Membership: id, Chunks: []string{}, Proof: proof}
	return encodeTestJSON(t, signedTestEnvelope(t, key, h)), name
}
