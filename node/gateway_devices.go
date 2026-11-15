package main

import (
	"encoding/json"
	"io"
	"maps"
	"net/http"
	"net/netip"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// gatewayProfile 是网关为每台设备记下的展示信息：设备名与最近一次请求的出口 IP。
// 这些都是设备自己报给网关的元数据，不含任何笔记内容。
type gatewayProfile struct {
	Name string    `json:",omitempty"`
	IP   string    `json:",omitempty"`
	Seen time.Time `json:",omitzero"`
}

type gatewayDeviceView struct {
	Device string `json:"device"`
	Name   string `json:"name,omitempty"`
	IP     string `json:"ip,omitempty"`
	Region string `json:"region,omitempty"`
	Seen   int64  `json:"seen,omitempty"`
}

const gatewayDevicesPath = "/seqpoint/relay/v2/devices"

// 持久化 Seen 的最小间隔；更频繁的上报只更新内存，避免每次同步都重写登记表。
const gatewaySeenPersist = 10 * time.Minute

func validDeviceName(name string) bool {
	if name == "" || !utf8.ValidString(name) || utf8.RuneCountInString(name) > 64 ||
		strings.TrimSpace(name) != name {
		return false
	}
	return !strings.ContainsFunc(name, unicode.IsControl)
}

// serveDevices：GET 列出同一空间内各设备的名称、出口 IP 与地区；
// POST {"name":…} 先登记本机名称和出口 IP，再返回列表。请求按中继 v2 规则签名。
func (g *gateway) serveDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1024))
	if err != nil {
		http.Error(w, "body too large", 413)
		return
	}
	id, device := r.URL.Query().Get("vault"), r.Header.Get("X-Seqpoint-Device")
	g.mu.RLock()
	n, v, failed := g.nodes[id], g.registry.Vaults[id], g.registryFailed
	g.mu.RUnlock()
	if failed {
		http.Error(w, "registry unavailable", 503)
		return
	}
	if n == nil || v.Devices[device] == "" || v.Revoked[device] || !n.authenticate(r, body) {
		http.Error(w, "unauthorized", 401)
		return
	}
	if v.Paused {
		http.Error(w, "vault paused", 403)
		return
	}
	if r.Method == "POST" {
		var report struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(body, &report); err != nil || !validDeviceName(report.Name) {
			http.Error(w, "invalid name", 400)
			return
		}
		ip := ""
		if addr := clientAddr(r); addr.IsValid() {
			ip = addr.String()
		}
		if err := g.recordProfile(id, device, gatewayProfile{Name: report.Name, IP: ip, Seen: time.Now().UTC()}); err != nil {
			http.Error(w, "registry unavailable", 503)
			return
		}
	}
	g.mu.RLock()
	v = g.registry.Vaults[id]
	views := make([]gatewayDeviceView, 0, len(v.Devices))
	for d := range v.Devices {
		if v.Revoked[d] {
			continue
		}
		p := v.Profiles[d]
		if live, ok := g.seen[id+"/"+d]; ok {
			p = live
		}
		view := gatewayDeviceView{Device: d, Name: p.Name, IP: p.IP}
		if addr, err := netip.ParseAddr(p.IP); err == nil {
			view.Region = g.regions.lookup(addr)
		}
		if !p.Seen.IsZero() {
			view.Seen = p.Seen.Unix()
		}
		views = append(views, view)
	}
	g.mu.RUnlock()
	sort.Slice(views, func(i, j int) bool { return views[i].Device < views[j].Device })
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"devices": views})
}

func (g *gateway) recordProfile(vault, device string, next gatewayProfile) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.registryFailed {
		return errUnauthorized
	}
	v, ok := g.registry.Vaults[vault]
	if !ok || v.Devices[device] == "" || v.Revoked[device] {
		return errUnauthorized
	}
	if g.seen == nil {
		g.seen = map[string]gatewayProfile{}
	}
	g.seen[vault+"/"+device] = next
	prev := v.Profiles[device]
	if prev.Name == next.Name && prev.IP == next.IP && next.Seen.Sub(prev.Seen) < gatewaySeenPersist {
		return nil
	}
	reg := gatewayRegistry{Invites: g.registry.Invites, Vaults: maps.Clone(g.registry.Vaults)}
	v.Profiles = maps.Clone(v.Profiles)
	if v.Profiles == nil {
		v.Profiles = map[string]gatewayProfile{}
	}
	v.Profiles[device] = next
	reg.Vaults[vault] = v
	return g.commit(reg)
}
