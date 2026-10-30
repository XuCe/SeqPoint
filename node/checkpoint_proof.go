package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"fmt"
)

func (n *Node) checkpointProof(h contentManifest, old *contentManifest) error {
	payload, err := decode64(h.Proof.Payload)
	if err != nil {
		return fmt.Errorf("proof encoding: %w", err)
	}
	var p struct {
		Domain   string `json:"domain"`
		Vault    string `json:"vault"`
		Author   string `json:"author"`
		Sequence int64  `json:"sequence"`
		Anchor   string `json:"anchor"`
	}
	if json.Unmarshal(payload, &p) != nil || p.Domain != "seqpoint-checkpoint-v2" || p.Vault != h.Vault ||
		p.Author != h.Author || p.Sequence != h.Sequence || p.Anchor != h.Anchor {
		return fmt.Errorf("proof context mismatch")
	}
	if old != nil && old.Proof == h.Proof {
		return nil
	}
	if h.Writer != h.Author {
		return fmt.Errorf("forwarding requires existing original proof")
	}
	signature, err := decode64(h.Proof.Signature)
	key := n.keys[h.Author]
	if err != nil || len(key) != ed25519.PublicKeySize || !ed25519.Verify(key, payload, signature) {
		return fmt.Errorf("original proof signature invalid")
	}
	return nil
}

func (n *Node) checkpointAnchor(h contentManifest, name string, old *contentManifest) error {
	if old != nil && old.Sequence == h.Sequence && old.Anchor == h.Anchor {
		return nil
	}
	if h.Writer != h.Author {
		return fmt.Errorf("only original author may advance checkpoint")
	}
	path := "ops/" + h.Author + "/" + name
	if !filePattern.MatchString(path) {
		return fmt.Errorf("invalid covered segment path")
	}
	if err := n.checkLinks(path); err != nil {
		return err
	}
	code, data := n.file("GET", path, nil)
	if code != 200 || fmt.Sprintf("%x", sha256.Sum256(data)) != h.Anchor {
		return fmt.Errorf("covered segment unavailable")
	}
	split := bytes.IndexByte(data, '\n')
	if split < 0 || split > 16384 {
		return fmt.Errorf("invalid covered header")
	}
	var head struct {
		Device   string `json:"device_id"`
		Sequence int64  `json:"seq"`
		Sealed   bool   `json:"sealed"`
	}
	if json.Unmarshal(data[:split], &head) != nil || head.Device != h.Author || head.Sequence != h.Sequence || !head.Sealed {
		return fmt.Errorf("covered prefix must be sealed")
	}
	return nil
}
