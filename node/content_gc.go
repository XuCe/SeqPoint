package main

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"strings"
	"time"
)

// Unreferenced uploads have a 24 hour grace; current checkpoints and all
// media manifests retain their chunks, including recoverable deleted media.
func (n *Node) reclaimContent(now time.Time) error {
	live, keep := map[string]bool{}, map[string]bool{}
	remove := []string{}
	err := fs.WalkDir(n.root.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasPrefix(path, "checkpoints/") {
			return nil
		}
		if !filePattern.MatchString(path) {
			return nil
		}
		if err := n.checkLinks(path); err != nil {
			return err
		}
		data, err := n.root.ReadFile(path)
		if err != nil {
			return err
		}
		live[fmt.Sprintf("%x", sha256.Sum256(data))] = true
		return nil
	})
	if err != nil {
		return fmt.Errorf("scan checkpoint roots: %w", err)
	}
	err = fs.WalkDir(n.root.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasPrefix(path, "manifests/") {
			return nil
		}
		if !filePattern.MatchString(path) {
			return nil
		}
		if err := n.checkLinks(path); err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Size() > maxFile {
			return fmt.Errorf("manifest too large")
		}
		data, err := n.root.ReadFile(path)
		if err != nil {
			return err
		}
		h, _, _, err := parseManifest(data)
		if err != nil {
			return err
		}
		if h.Kind == "checkpoint" && !live[fmt.Sprintf("%x", sha256.Sum256(data))] && now.Sub(info.ModTime()) > 24*time.Hour {
			remove = append(remove, path)
			return nil
		}
		for _, hash := range h.Chunks {
			keep["blobs/"+h.Writer+"/"+hash+".bin"] = true
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("scan live manifests: %w", err)
	}
	err = fs.WalkDir(n.root.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasPrefix(path, "blobs/") || keep[path] {
			return nil
		}
		if !filePattern.MatchString(path) {
			return nil
		}
		if err := n.checkLinks(path); err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if now.Sub(info.ModTime()) > 24*time.Hour {
			remove = append(remove, path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("scan unused chunks: %w", err)
	}
	for _, path := range remove {
		if err := n.root.Remove(path); err != nil {
			return fmt.Errorf("reclaim content: %w", err)
		}
	}
	return nil
}
