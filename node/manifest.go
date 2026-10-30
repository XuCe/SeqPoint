package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

type signedEnvelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}
type contentManifest struct {
	Version    int            `json:"version"`
	Kind       string         `json:"kind"`
	Vault      string         `json:"vault"`
	Writer     string         `json:"writer"`
	Author     string         `json:"author"`
	Epoch      int64          `json:"epoch"`
	Subject    string         `json:"subject"`
	Sequence   int64          `json:"sequence"`
	Anchor     string         `json:"anchor"`
	Membership string         `json:"membership"`
	Chunks     []string       `json:"chunks"`
	Proof      signedEnvelope `json:"proof"`
}

var digestPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var identityPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

func decode64(value string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(value, "="))
}
func parseManifest(data []byte) (contentManifest, []byte, []byte, error) {
	var envelope signedEnvelope
	var h contentManifest
	if err := json.Unmarshal(data, &envelope); err != nil {
		return h, nil, nil, fmt.Errorf("manifest envelope: %w", err)
	}
	payload, err := decode64(envelope.Payload)
	if err != nil {
		return h, nil, nil, fmt.Errorf("manifest payload: %w", err)
	}
	if err = json.Unmarshal(payload, &h); err != nil {
		return h, nil, nil, fmt.Errorf("manifest header: %w", err)
	}
	signature, err := decode64(envelope.Signature)
	return h, payload, signature, err
}
func (n *Node) verifyManifest(data []byte) (contentManifest, error) {
	h, payload, signature, err := parseManifest(data)
	key := n.keys[h.Writer]
	if err != nil || len(key) != ed25519.PublicKeySize || !ed25519.Verify(key, payload, signature) ||
		h.Version != 2 || h.Vault != n.config.VaultID || !identityPattern.MatchString(h.Author) ||
		h.Epoch < 1 || h.Sequence < 0 || !digestPattern.MatchString(h.Anchor) || !identityPattern.MatchString(h.Membership) ||
		(h.Kind != "media" && h.Kind != "checkpoint") || len(h.Chunks) > 16384 {
		return h, fmt.Errorf("invalid manifest")
	}
	for _, hash := range h.Chunks {
		if !digestPattern.MatchString(hash) {
			return h, fmt.Errorf("invalid chunk hash")
		}
		path := "blobs/" + h.Writer + "/" + hash + ".bin"
		if err := n.checkLinks(path); err != nil {
			return h, err
		}
		info, err := n.root.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > (1<<20)+40 {
			return h, fmt.Errorf("chunk unavailable")
		}
		data, err := n.root.ReadFile(path)
		if err != nil {
			return h, fmt.Errorf("read chunk commitment: %w", err)
		}
		if fmt.Sprintf("%x", sha256.Sum256(data)) != hash {
			return h, fmt.Errorf("chunk commitment damaged")
		}
	}
	return h, nil
}
