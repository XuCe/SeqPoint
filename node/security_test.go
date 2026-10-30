package main

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIsolationAndTampering(t *testing.T) {
	n, key, id := fixture(t)
	cases := []struct {
		method, action, path string
		code                 int
	}{
		{"PUT", "file", "members/" + strings.Repeat("a", 43) + ".json", 403},
		{"PUT", "file", "../escape", 400},
		{"GET", "file", "/etc/passwd", 400},
		{"GET", "list", "ops/../members", 400},
		{"DELETE", "file", "members/" + id + ".json", 405},
	}
	for _, c := range cases {
		w := httptest.NewRecorder()
		n.ServeHTTP(w, signed(t, n, key, id, c.method, c.action, c.path, ""))
		if w.Code != c.code {
			t.Errorf("%s %s: status %d", c.method, c.path, w.Code)
		}
	}
	for _, change := range []string{"body", "vault", "signature"} {
		r := signed(t, n, key, id, "PUT", "file", "members/"+id+".json", "original")
		switch change {
		case "body":
			r.Body = io.NopCloser(strings.NewReader("changed"))
		case "vault":
			r.URL.RawQuery = "vault=other&path=members/" + id + ".json"
		case "signature":
			r.Header.Set("X-Seqpoint-Signature", "invalid")
		}
		w := httptest.NewRecorder()
		n.ServeHTTP(w, r)
		if w.Code != 401 {
			t.Errorf("%s tampering status %d", change, w.Code)
		}
	}
}
