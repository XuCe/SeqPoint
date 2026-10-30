package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRejectAnonymous(t *testing.T) {
	n := &Node{}
	w := httptest.NewRecorder()
	n.ServeHTTP(w, httptest.NewRequest("GET", "/seqpoint/relay/v1/usage", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous status = %d", w.Code)
	}
}
