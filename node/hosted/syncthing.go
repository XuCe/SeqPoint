package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

var localAPI = &http.Client{
	Timeout:       8 * time.Second,
	Transport:     &http.Transport{Proxy: nil},
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
}

type syncthing struct{ url, key, root string }

func (s syncthing) call(ctx context.Context, method, path string, body any) (map[string]any, error) {
	var data []byte
	var err error
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("encode config: %w", err)
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, s.url+"/rest/"+path, bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("X-API-Key", s.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := localAPI.Do(req)
	if err != nil {
		return nil, fmt.Errorf("contact local engine: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 404 && method == "GET" {
		return nil, nil
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("local engine returned %d", resp.StatusCode)
	}
	if method != "GET" {
		return nil, nil
	}
	var result map[string]any
	if err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&result); err != nil {
		return nil, fmt.Errorf("read engine response: %w", err)
	}
	return result, nil
}

func (s syncthing) share(ctx context.Context, e enrollment, v vault) (string, error) {
	status, err := s.call(ctx, "GET", "system/status", nil)
	if err != nil {
		return "", err
	}
	id, _ := status["myID"].(string)
	if !deviceID.MatchString(id) || id == e.Device {
		return "", fmt.Errorf("invalid peer identity")
	}
	device, err := s.call(ctx, "GET", "config/devices/"+e.Device, nil)
	if err != nil {
		return "", err
	}
	if device == nil {
		if _, err = s.call(ctx, "PUT", "config/devices/"+e.Device, map[string]any{"deviceID": e.Device, "name": "SeqPoint"}); err != nil {
			return "", err
		}
	}
	path := "config/folders/" + e.Folder
	folder, err := s.call(ctx, "GET", path, nil)
	if err != nil {
		return "", err
	}
	directory := s.root + "/" + v.Slot
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("allocated data directory missing")
	}
	if folder == nil {
		folder, err = s.call(ctx, "GET", "config/defaults/folder", nil)
		if err != nil {
			return "", err
		}
		if folder == nil {
			return "", fmt.Errorf("missing folder defaults")
		}
		folder["id"] = e.Folder
		folder["path"] = directory
		folder["label"] = "SeqPoint"
		folder["type"] = "sendreceive"
		folder["paused"] = false
	} else if folder["path"] != directory {
		return "", fmt.Errorf("folder collision")
	}
	peers := []map[string]string{{"deviceID": id}}
	for _, member := range v.Members {
		peers = append(peers, map[string]string{"deviceID": member})
	}
	folder["devices"] = peers
	_, err = s.call(ctx, "PUT", path, folder)
	return id, err
}
