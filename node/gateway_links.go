package main

import (
	"encoding/json"
	"net/http"
	"os"
	"regexp"
)

var androidCert = regexp.MustCompile("^(?:[A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}$")
var appleTeam = regexp.MustCompile("^[A-Z0-9]{10}$")

func gatewayLinks(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "HEAD" {
		http.Error(w, "method", 405)
		return
	}
	var data any
	switch r.URL.Path {
	case "/.well-known/assetlinks.json":
		cert := os.Getenv("GATEWAY_ANDROID_SHA256")
		if androidCert.MatchString(cert) {
			data = []any{map[string]any{"relation": []string{"delegate_permission/common.handle_all_urls"},
				"target": map[string]any{"namespace": "android_app", "package_name": "com.seqpoint.app", "sha256_cert_fingerprints": []string{cert}}}}
		}
	case "/.well-known/apple-app-site-association":
		team := os.Getenv("GATEWAY_APPLE_TEAM")
		if appleTeam.MatchString(team) {
			data = map[string]any{"applinks": map[string]any{"details": []any{map[string]any{"appIDs": []string{team + ".com.seqpoint.seqpointApp"}, "components": []any{map[string]string{"/": "/invite"}}}}}}
		}
	}
	if data == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}
