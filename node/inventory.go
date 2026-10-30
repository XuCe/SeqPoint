package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
)

// Digests avoid resending unchanged tails, membership and encrypted chunks.
func (n *Node) inventory(body []byte) (int, []byte) {
	var paths []string
	if json.Unmarshal(body, &paths) != nil || len(paths) > 256 {
		return 400, nil
	}
	hashes := make(map[string]string, len(paths))
	for _, path := range paths {
		if !filePattern.MatchString(path) {
			return 400, nil
		}
		if err := n.checkLinks(path); err != nil {
			return 400, nil
		}
		info, err := n.root.Stat(path)
		if os.IsNotExist(err) {
			hashes[path] = ""
			continue
		}
		if err != nil {
			return 500, nil
		}
		if !info.Mode().IsRegular() || info.Size() > maxFile {
			return 413, nil
		}
		data, err := n.root.ReadFile(path)
		if err != nil {
			return 500, nil
		}
		hashes[path] = fmt.Sprintf("%x", sha256.Sum256(data))
	}
	data, err := json.Marshal(hashes)
	if err != nil {
		return 500, nil
	}
	return 200, data
}
