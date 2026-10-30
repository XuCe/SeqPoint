package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

var filePattern = regexp.MustCompile(`^(ops/([A-Za-z0-9_-]{43})/[0-9]{6}-[0-9]{4,}\.log|members/([A-Za-z0-9_-]{43})\.json|acks/([A-Za-z0-9_-]{43})\.json|(blobs|manifests)/[A-Za-z0-9_-]{43}/[a-f0-9]{64}\.(bin|json)|checkpoints/[A-Za-z0-9_-]{43}\.json)$`)
var listPattern = regexp.MustCompile(`^(members|acks|ops/[A-Za-z0-9_-]{43})$`)

func owns(path, device string) bool {
	return strings.HasPrefix(path, "ops/"+device+"/") ||
		path == "members/"+device+".json" || path == "acks/"+device+".json" ||
		strings.HasPrefix(path, "blobs/"+device+"/") || strings.HasPrefix(path, "manifests/"+device+"/")
}

func (n *Node) checkLinks(path string) error {
	parts := strings.Split(path, "/")
	for i := range parts {
		info, err := n.root.Lstat(strings.Join(parts[:i+1], "/"))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect data path: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("symbolic links are forbidden")
		}
	}
	return nil
}
