package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
)

func (n *Node) checkpoint(author, device string, body []byte) (int, []byte) {
	var request struct {
		Previous string `json:"previous"`
		Manifest string `json:"manifest"`
		Segment  string `json:"segment"`
	}
	if !identityPattern.MatchString(author) || json.Unmarshal(body, &request) != nil {
		return 400, nil
	}
	data, err := decode64(request.Manifest)
	if err != nil || len(data) > maxFile {
		return 400, nil
	}
	h, err := n.verifyManifest(data)
	if err != nil || h.Kind != "checkpoint" || h.Author != author || h.Subject != author || h.Writer != device || h.Sequence < 1 {
		return 409, nil
	}
	path := "checkpoints/" + author + ".json"
	if err := n.checkLinks(path); err != nil {
		return 400, nil
	}
	previous, err := n.root.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return 500, nil
	}
	var old *contentManifest
	current := ""
	if err == nil {
		value, _, _, err := parseManifest(previous)
		if err != nil {
			return 500, nil
		}
		old = &value
		current = fmt.Sprintf("%x", sha256.Sum256(previous))
		if h.Sequence < old.Sequence || h.Epoch < old.Epoch || (h.Sequence == old.Sequence && h.Anchor != old.Anchor) {
			return 409, nil
		}
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(data))
	if current != digest && current != request.Previous {
		return 409, nil
	}
	if n.checkpointProof(h, old) != nil || n.checkpointAnchor(h, request.Segment, old) != nil {
		return 409, nil
	}
	if code, _ := n.file("PUT", "manifests/"+h.Writer+"/"+digest+".json", data); code != 204 {
		return code, nil
	}
	// Protocol barrier is durable before any log can disappear.
	if err := n.atomicWrite("protocol-v2", []byte("2")); err != nil {
		return 500, nil
	}
	if code, _ := n.file("PUT", path, data); code != 204 {
		return code, nil
	}
	removed, err := n.reclaimCovered(author, h.Sequence)
	if err != nil {
		return 500, nil
	}
	response, err := json.Marshal(map[string]any{"hash": digest, "reclaimed": removed})
	if err != nil {
		return 500, nil
	}
	return 200, response
}
