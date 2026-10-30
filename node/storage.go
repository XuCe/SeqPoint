package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"strings"
)

func (n *Node) usedBytes() (int64, error) {
	var total int64
	err := fs.WalkDir(n.root.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("walk data: %w", err)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("symbolic link in data")
		}
		if filePattern.MatchString(path) && !entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				return fmt.Errorf("inspect stored file: %w", err)
			}
			total += info.Size()
		}
		return nil
	})
	return total, err
}

func (n *Node) file(method, path string, body []byte) (int, []byte) {
	immutable := strings.HasPrefix(path, "blobs/") || strings.HasPrefix(path, "manifests/")
	if method == "PUT" && immutable {
		parts := strings.Split(path, "/")
		if strings.Split(parts[2], ".")[0] != fmt.Sprintf("%x", sha256.Sum256(body)) {
			return 409, nil
		}
		if parts[0] == "blobs" && len(body) > (1<<20)+40 {
			return 413, nil
		}
		if parts[0] == "manifests" {
			h, err := n.verifyManifest(body)
			if err != nil || h.Writer != parts[1] {
				return 409, nil
			}
		}
	}
	info, err := n.root.Stat(path)
	if err != nil && !os.IsNotExist(err) {
		return 500, nil
	}
	var oldSize int64
	if err == nil {
		if !info.Mode().IsRegular() || info.Size() > maxFile {
			return 413, nil
		}
		oldSize = info.Size()
		if method == "PUT" && immutable && oldSize == int64(len(body)) {
			stored, err := n.root.ReadFile(path)
			if err != nil {
				return 500, nil
			}
			if bytes.Equal(stored, body) {
				return 204, nil
			}
		}
	}
	if method == "GET" {
		if os.IsNotExist(err) {
			return 404, nil
		}
		bytes, err := n.root.ReadFile(path)
		if err != nil {
			return 500, nil
		}
		return 200, bytes
	}
	used, err := n.usedBytes()
	if err != nil {
		return 500, nil
	}
	if used-oldSize+int64(len(body)) > n.config.QuotaBytes {
		return 413, nil
	}
	if err := n.atomicWrite(path, body); err != nil {
		return 500, nil
	}
	return 204, nil
}
