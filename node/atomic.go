package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

func (n *Node) atomicWrite(path string, body []byte) (result error) {
	if err := n.root.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create parent: %w", err)
	}
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return fmt.Errorf("temporary name: %w", err)
	}
	temp := path + ".tmp-" + hex.EncodeToString(random)
	file, err := n.root.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	defer func() {
		if err := n.root.Remove(temp); err != nil && !os.IsNotExist(err) {
			result = errors.Join(result, fmt.Errorf("remove temporary file: %w", err))
		}
	}()
	_, writeErr := file.Write(body)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return fmt.Errorf("persist temporary file: %w", err)
	}
	if err := n.root.Rename(temp, path); err != nil {
		return fmt.Errorf("replace file: %w", err)
	}
	// Persist both the rename and any newly created ancestor directories.
	for parent := filepath.Dir(path); ; parent = filepath.Dir(parent) {
		directory, err := n.root.Open(parent)
		if err != nil {
			return fmt.Errorf("open parent for sync: %w", err)
		}
		if err := errors.Join(directory.Sync(), directory.Close()); err != nil {
			return fmt.Errorf("persist directory: %w", err)
		}
		if parent == "." {
			break
		}
	}
	return nil
}
