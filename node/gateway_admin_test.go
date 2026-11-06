package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGatewayAdminHTTPForm(t *testing.T) {
	g, err := openGateway(t.TempDir(), "http://gateway.test:8385")
	if err != nil {
		t.Fatal(err)
	}
	defer g.close()
	admin := g.admin("test-password")
	page := httptest.NewRequest("GET", "http://gateway.test:8386/", nil)
	page.SetBasicAuth("admin", "test-password")
	w := httptest.NewRecorder()
	admin.ServeHTTP(w, page)
	if w.Code != 200 || w.Header().Get("Referrer-Policy") != "same-origin" {
		t.Fatalf("HTTP form must retain its origin: status=%d policy=%q", w.Code, w.Header().Get("Referrer-Policy"))
	}
	for _, origin := range []string{"http://gateway.test:8386", "null", "http://other.test:8386", "http://gateway.test:8385"} {
		t.Run(origin, func(t *testing.T) {
			r := httptest.NewRequest("POST", "http://gateway.test:8386/", strings.NewReader("action=invite"))
			r.SetBasicAuth("admin", "test-password")
			r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			r.Header.Set("Origin", origin)
			w := httptest.NewRecorder()
			admin.ServeHTTP(w, r)
			want := 403
			if origin == "http://gateway.test:8386" {
				want = 200
				if !strings.Contains(w.Body.String(), "http://gateway.test:8385/invite#gw.") {
					t.Fatal("invitation missing")
				}
			}
			if w.Code != want {
				t.Fatalf("status=%d want=%d", w.Code, want)
			}
		})
	}
}
