package main

import (
	"encoding/json"
	"io/fs"
	"os"
)

type remoteFile struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
}

func (n *Node) list(path string) (int, []byte) {
	entries, err := fs.ReadDir(n.root.FS(), path)
	if err != nil && !os.IsNotExist(err) {
		return 500, nil
	}
	files := make([]remoteFile, 0)
	for _, entry := range entries {
		if !filePattern.MatchString(path + "/" + entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			return 500, nil
		}
		files = append(files, remoteFile{Name: entry.Name(), Size: info.Size()})
	}
	if len(files) > 1024 {
		return 413, nil
	}
	bytes, err := json.Marshal(files)
	if err != nil {
		return 500, nil
	}
	return 200, bytes
}
