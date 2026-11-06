package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"

	"time"
)

type service struct {
	origin, state string
	engine        syncthing
	busy          chan struct{}
}

func (s *service) enroll(w http.ResponseWriter, r *http.Request) {
	var e enrollment
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&e); err != nil || !e.valid(s.origin) {
		http.Error(w, "invalid enrollment", 400)
		return
	}
	select {
	case s.busy <- struct{}{}:
		defer func() { <-s.busy }()
	default:
		w.Header().Set("Retry-After", "2")
		http.Error(w, "node busy, retry", http.StatusServiceUnavailable)
		return
	}
	if r.Context().Err() != nil {
		return
	}
	v, err := reserve(s.state, s.origin, e)
	if errors.Is(err, denied) {
		http.Error(w, "invitation or device not authorized", 403)
		return
	}
	if err == nil {
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		var id string
		id, err = s.engine.share(ctx, e, v)
		if err == nil {
			w.Header().Set("Content-Type", "application/json")
			if err = json.NewEncoder(w).Encode(map[string]string{"device": id}); err != nil {
				log.Printf("send enrollment: %v", err)
			}
			return
		}
	}
	log.Printf("provision: %v", err)
	http.Error(w, "node unavailable", 503)
}
func main() {
	origin, root, data, key := os.Getenv("HOSTED_ORIGIN"), os.Getenv("HOSTED_STATE"), os.Getenv("HOSTED_DATA"), os.Getenv("STGUIAPIKEY")
	u, err := url.Parse(origin)
	if err != nil || u.Scheme != "https" || u.Host == "" || origin != "https://"+u.Host || !filepath.IsAbs(root) || !filepath.IsAbs(data) || key == "" {
		log.Fatal("set HOSTED_ORIGIN, HOSTED_STATE, HOSTED_DATA and STGUIAPIKEY")
	}
	s := service{busy: make(chan struct{}, 1), origin: origin, state: root, engine: syncthing{"http://127.0.0.1:8384", key, data}}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/enroll", s.enroll)
	mux.HandleFunc("GET /invite", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		_, err := w.Write([]byte(`<!doctype html><html lang="zh"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>序点 · 云同步邀请</title>
<main style="max-width:32em;margin:12vh auto;padding:1rem;font:1.1rem/1.7 system-ui">
<h1>序点云同步邀请</h1><p>复制邀请链接，在序点的「设置 → 同步 → 启用云同步」中粘贴并确认。</p>
<button id="copy">复制邀请链接</button><p id="status" role="status"></p></main>
<script>document.querySelector('#copy').onclick=async()=>{const status=document.querySelector('#status');
try{await navigator.clipboard.writeText(location.href);status.textContent='已复制，可以打开序点了。'}
catch{status.textContent='请从浏览器地址栏复制完整链接。'}}</script></html>`))
		if err != nil {
			log.Printf("send invitation page: %v", err)
		}
	})
	server := http.Server{Addr: "127.0.0.1:8385", Handler: mux, MaxHeaderBytes: 8192, ReadTimeout: 8 * time.Second, WriteTimeout: 25 * time.Second, IdleTimeout: 30 * time.Second}
	log.Fatal(server.ListenAndServe())
}
