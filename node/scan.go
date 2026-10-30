package main

import (
	"encoding/json"
	"io"
	"os"
	"sort"
	"strings"
)

// Scan has bounded memory even when a device has years of segments.
func (n *Node) scan(path string, body []byte) (int, []byte) {
	var request struct {
		After string `json:"after"`
	}
	if !listPattern.MatchString(path) || json.Unmarshal(body, &request) != nil || strings.ContainsAny(request.After, "/\\") {
		return 400, nil
	}
	if err := n.checkLinks(path); err != nil {
		return 400, nil
	}
	dir, err := n.root.Open(path)
	if os.IsNotExist(err) {
		return 200, []byte(`{"files":[],"next":null}`)
	}
	if err != nil {
		return 500, nil
	}
	defer dir.Close()
	files := make([]remoteFile, 0, 257)
	for {
		entries, readErr := dir.ReadDir(128)
		if readErr != nil && readErr != io.EOF {
			return 500, nil
		}
		for _, entry := range entries {
			if entry.Name() <= request.After || !filePattern.MatchString(path+"/"+entry.Name()) {
				continue
			}
			info, err := entry.Info()
			if err != nil || !info.Mode().IsRegular() {
				return 500, nil
			}
			files = append(files, remoteFile{Name: entry.Name(), Size: info.Size()})
		}
		sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
		if len(files) > 257 {
			files = files[:257]
		}
		if readErr == io.EOF {
			break
		}
	}
	var next *string
	if len(files) > 256 {
		files = files[:256]
		value := files[255].Name
		next = &value
	}
	data, err := json.Marshal(map[string]any{"files": files, "next": next})
	if err != nil {
		return 500, nil
	}
	return 200, data
}
