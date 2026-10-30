package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

func (n *Node) reclaimCovered(author string, sequence int64) (int, error) {
	path := "ops/" + author
	if err := n.checkLinks(path); err != nil {
		return 0, err
	}
	dir, err := n.root.Open(path)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("open history: %w", err)
	}
	defer dir.Close()
	removed := 0
	for {
		entries, readErr := dir.ReadDir(128)
		if readErr != nil && readErr != io.EOF {
			return removed, fmt.Errorf("read history: %w", readErr)
		}
		for _, entry := range entries {
			name := entry.Name()
			if !filePattern.MatchString(path + "/" + name) {
				continue
			}
			parts := strings.Split(strings.TrimSuffix(name, ".log"), "-")
			seq, err := strconv.ParseInt(parts[len(parts)-1], 10, 64)
			if err != nil || seq > sequence {
				continue
			}
			if err := n.checkLinks(path + "/" + name); err != nil {
				return removed, err
			}
			code, data := n.file("GET", path+"/"+name, nil)
			split := bytes.IndexByte(data, '\n')
			if code != 200 || split < 0 || split > 16384 {
				return removed, fmt.Errorf("invalid history for GC")
			}
			var h struct {
				Sealed bool   `json:"sealed"`
				Seq    int64  `json:"seq"`
				Device string `json:"device_id"`
			}
			if json.Unmarshal(data[:split], &h) != nil || !h.Sealed || h.Seq != seq || h.Device != author {
				continue
			}
			if err := n.root.Remove(path + "/" + name); err != nil {
				return removed, fmt.Errorf("remove covered history: %w", err)
			}
			removed++
		}
		if readErr == io.EOF {
			break
		}
	}
	if err := dir.Sync(); err != nil {
		return removed, fmt.Errorf("persist history GC: %w", err)
	}
	return removed, nil
}
