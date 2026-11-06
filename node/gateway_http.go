package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if strings.HasPrefix(r.URL.Path, "/.well-known/") {
		gatewayLinks(w, r)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/invite" {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Referrer-Policy", "no-referrer")
		fmt.Fprint(w, `<!doctype html><html lang="zh"><meta charset=utf-8><meta name="viewport" content="width=device-width,initial-scale=1"><title>序点云同步邀请</title><main style="max-width:34em;margin:12vh auto;padding:1rem;font:1.1rem/1.7 system-ui"><h1>序点云同步邀请</h1><p>已安装序点时，可在关联域名的邀请上直接打开应用。也可以复制邀请，进入「设置 → 同步 → 启用云同步」。</p><p><a id="launch" hidden>在序点中打开</a></p><label for="invite">完整邀请链接（可长按或选中复制）</label><textarea id="invite" readonly style="width:100%;height:6em" onclick="this.select()"></textarea><p id="copy-status" role="status"></p><script>document.getElementById('invite').value=location.href;async function copyInvite(){try{await navigator.clipboard.writeText(location.href);document.getElementById('copy-status').textContent='已复制';return true}catch{document.getElementById('invite').select();document.getElementById('copy-status').textContent='请复制上方选中的完整链接，再进入序点同步设置粘贴';return false}}if(/Android/i.test(navigator.userAgent)){const a=document.getElementById('launch');const payload=btoa(location.href).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');a.href='intent://open/invite?open='+payload+'#Intent;scheme=seqpoint;package=com.seqpoint.app;end';a.hidden=false}else{const a=document.getElementById('launch');a.hidden=false;a.textContent='复制邀请并打开序点';a.href='seqpoint-gateway://open/paste';a.onclick=async e=>{e.preventDefault();if(await copyInvite()){location.href=a.href}}}</script><button onclick="copyInvite()">复制邀请链接</button></main></html>`)
		return
	}
	if r.Method == "POST" && r.URL.Path == "/v1/enroll" {
		var c gatewayClaim
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&c); err != nil || !c.valid(g.origin) {
			http.Error(w, "invalid proof", 401)
			return
		}
		err := g.claim(c)
		if errors.Is(err, errUnauthorized) {
			http.Error(w, "denied", 403)
			return
		}
		if err != nil {
			http.Error(w, "registry unavailable", 503)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"device":%q}`, c.Device)
		return
	}
	if !strings.HasPrefix(r.URL.Path, "/seqpoint/relay/v2/") {
		http.NotFound(w, r)
		return
	}
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
	default:
		http.Error(w, "busy", 503)
		return
	}
	g.mu.RLock()
	defer g.mu.RUnlock()
	if g.registryFailed {
		http.Error(w, "registry unavailable", 503)
		return
	}
	id := r.URL.Query().Get("vault")
	n := g.nodes[id]
	v := g.registry.Vaults[id]
	if n == nil || v.Devices[r.Header.Get("X-Seqpoint-Device")] == "" || v.Revoked[r.Header.Get("X-Seqpoint-Device")] {
		http.Error(w, "unauthorized", 401)
		return
	}
	if v.Paused {
		http.Error(w, "vault paused", 403)
		return
	}
	if r.Method == "PUT" || strings.HasSuffix(r.URL.Path, "/checkpoint") {
		if !gatewayHasRoom(g.directory) {
			http.Error(w, "disk reserve", 507)
			return
		}
	}
	n.ServeHTTP(w, r)
}
