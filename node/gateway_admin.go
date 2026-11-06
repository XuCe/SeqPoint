package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"html/template"
	"net/http"
)

var adminPage = template.Must(template.New("admin").Parse(`<!doctype html><html lang="zh"><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>序点网关</title><style>body{max-width:55rem;margin:3rem auto;padding:1rem;font:1rem/1.6 system-ui}form{margin:1em 0}input,button{font:inherit}code{overflow-wrap:anywhere}section{border-top:1px solid #bbb}</style>
<h1>序点同步网关</h1><h2>开通邀请</h2><form method=post><button name=action value=invite>生成七天有效邀请</button></form>
{{if .Link}}<p>将此链接发给首台设备。离开本页后无法再次查看。</p><input aria-label="邀请链接" readonly style="width:95%" onclick="this.select()" value="{{.Link}}">{{end}}
{{range $id,$t:=.Invites}}<form method=post><code>{{printf "%.12s" $id}}</code> · 到期 {{$t.Expires.UTC.Format "2006-01-02 15:04 UTC"}} <input type=hidden name=ticket value="{{$id}}"><button name=action value=cancel>取消邀请</button></form>{{end}}
<h2>资料库</h2>{{range .Vaults}}<section><p><code>{{.ID}}</code></p><p>{{.Members}} 台已授权设备 · 已用 {{.Bytes}} 字节</p><form method=post><input type=hidden name=vault value="{{.ID}}"><label>配额 MiB <input type=number min=1 name=quota required value="{{.Quota}}"></label> <label><input type=checkbox name=paused {{if .Paused}}checked{{end}}>暂停此空间</label> <button name=action value=update>保存</button></form></section>{{else}}<p>首台设备开通后，资料库将显示在这里。</p>{{end}}</html>`))

type adminVault struct {
	ID           string
	Members      int
	Bytes, Quota int64
	Paused       bool
}

func (g *gateway) admin(password string) http.Handler {
	protected := http.NewCrossOriginProtection().Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		link := ""
		if r.Method == "POST" {
			r.Body = http.MaxBytesReader(w, r.Body, 4096)
			if err := r.ParseForm(); err != nil {
				http.Error(w, "invalid form", 400)
				return
			}
			var err error
			link, err = g.manage(r.PostForm)
			if err != nil {
				http.Error(w, "无法保存，请检查输入与数据卷", 400)
				return
			}
		} else if r.Method != "GET" {
			http.Error(w, "method", 405)
			return
		}
		g.mu.RLock()
		defer g.mu.RUnlock()
		views := []adminVault{}
		for id, v := range g.registry.Vaults {
			n := g.nodes[id]
			n.mu.Lock()
			used, err := n.usedBytes()
			n.mu.Unlock()
			if err != nil {
				http.Error(w, "storage unavailable", 500)
				return
			}
			active := 0
			for device := range v.Devices {
				if !v.Revoked[device] {
					active++
				}
			}
			views = append(views, adminVault{id, active, used, v.QuotaBytes >> 20, v.Paused})
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		adminPage.Execute(w, map[string]any{"Link": link, "Invites": g.registry.Invites, "Vaults": views})
	}))
	want := sha256.Sum256([]byte(password))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Frame-Options", "DENY")
		// HTTP form POSTs need their Origin preserved for cross-origin checks.
		w.Header().Set("Referrer-Policy", "same-origin")
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		user, pass, ok := r.BasicAuth()
		got := sha256.Sum256([]byte(pass))
		if !ok || user != "admin" || subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="SeqPoint"`)
			http.Error(w, "login required", 401)
			return
		}
		protected.ServeHTTP(w, r)
	})
}
