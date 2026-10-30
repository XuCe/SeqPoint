package main

import (
	"crypto/ed25519"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const maxFile = 12 << 20

type Config struct {
	VaultID    string            `json:"vaultId"`
	Devices    map[string]string `json:"devices"`
	QuotaBytes int64             `json:"quotaBytes"`
}

type Node struct {
	config   Config
	keys     map[string]ed25519.PublicKey
	root     *os.Root
	mu       sync.Mutex
	nonces   map[string]time.Time
	requests chan struct{}
	lastGC   time.Time
}

func (n *Node) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.URL.Path, "/seqpoint/relay/v1/") && !strings.HasPrefix(r.URL.Path, "/seqpoint/relay/v2/") {
		http.NotFound(w, r)
		return
	}
	if _, known := n.keys[r.Header.Get("X-Seqpoint-Device")]; !known {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	select {
	case n.requests <- struct{}{}:
		defer func() { <-n.requests }()
	default:
		http.Error(w, "busy", http.StatusServiceUnavailable)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxFile))
	if err != nil {
		http.Error(w, "body limit", http.StatusRequestEntityTooLarge)
		return
	}
	if !n.authenticate(r, body) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	n.serveFiles(w, r, body)
}

func (n *Node) serveFiles(w http.ResponseWriter, r *http.Request, body []byte) {
	n.mu.Lock()
	defer n.mu.Unlock()
	path := r.URL.Query().Get("path")
	if r.Method == "PUT" && time.Since(n.lastGC) > time.Hour {
		if err := n.reclaimContent(time.Now()); err != nil {
			http.Error(w, "content GC failed", 500)
			return
		}
		n.lastGC = time.Now()
	}
	action := strings.TrimPrefix(r.URL.Path, "/seqpoint/relay/v1/")
	if strings.HasPrefix(r.URL.Path, "/seqpoint/relay/v1/") {
		if _, err := n.root.Stat("protocol-v2"); err == nil {
			http.Error(w, "Upgrade to sync protocol v2", http.StatusUpgradeRequired)
			return
		} else if !os.IsNotExist(err) {
			http.Error(w, "storage error", 500)
			return
		}
	}
	action = strings.TrimPrefix(action, "/seqpoint/relay/v2/")
	code, data := n.route(r.Method, action, path, r.Header.Get("X-Seqpoint-Device"), body)
	if code >= 400 {
		http.Error(w, http.StatusText(code), code)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(code)
	if len(data) > 0 {
		if _, err := w.Write(data); err != nil {
			log.Printf("write response: %v", err)
		}
	}
}

func (n *Node) route(method, action, path, device string, body []byte) (int, []byte) {
	if method == "POST" && action == "checkpoint" {
		return n.checkpoint(path, device, body)
	}
	if method == "POST" && action == "scan" {
		return n.scan(path, body)
	}
	if method == "POST" && action == "inventory" && path == "" {
		return n.inventory(body)
	}
	if method != "GET" && method != "PUT" {
		return 405, nil
	}
	if action == "usage" && method == "GET" && path == "" {
		used, err := n.usedBytes()
		if err != nil {
			return 500, nil
		}
		data, err := json.Marshal(map[string]int64{"used_bytes": used})
		if err != nil {
			return 500, nil
		}
		return 200, data
	}
	if action == "file" && filePattern.MatchString(path) {
		if method == "PUT" && !owns(path, device) {
			return 403, nil
		}
		if err := n.checkLinks(path); err != nil {
			return 400, nil
		}
		return n.file(method, path, body)
	}
	if action == "list" && method == "GET" && listPattern.MatchString(path) {
		if err := n.checkLinks(path); err != nil {
			return 400, nil
		}
		return n.list(path)
	}
	return 400, nil
}
