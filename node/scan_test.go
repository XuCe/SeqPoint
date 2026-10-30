package main

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestPagedHistoryAndInventory(t *testing.T) {
	n, _, id := fixture(t)
	for i := 1; i <= 1100; i++ {
		path := fmt.Sprintf("ops/%s/202610-%04d.log", id, i)
		if err := n.atomicWrite(path, []byte("frame")); err != nil {
			t.Fatal(err)
		}
	}
	after, total := "", 0
	for {
		request, err := json.Marshal(map[string]string{"after": after})
		if err != nil {
			t.Fatal(err)
		}
		code, data := n.route("POST", "scan", "ops/"+id, id, request)
		if code != 200 {
			t.Fatalf("scan %d", code)
		}
		var page struct {
			Files []remoteFile `json:"files"`
			Next  *string      `json:"next"`
		}
		if err := json.Unmarshal(data, &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Files) > 256 {
			t.Fatal("unbounded page")
		}
		for _, f := range page.Files {
			if f.Name <= after {
				t.Fatal("duplicate/out of order")
			}
			after = f.Name
			total++
		}
		if page.Next == nil {
			break
		}
		if *page.Next != after {
			t.Fatal("wrong cursor")
		}
	}
	if total != 1100 {
		t.Fatalf("files %d", total)
	}
	path := fmt.Sprintf("ops/%s/202610-0001.log", id)
	request, err := json.Marshal([]string{path, "acks/" + id + ".json"})
	if err != nil {
		t.Fatal(err)
	}
	code, data := n.route("POST", "inventory", "", id, request)
	var hashes map[string]string
	if code != 200 || json.Unmarshal(data, &hashes) != nil || len(hashes[path]) != 64 || hashes["acks/"+id+".json"] != "" {
		t.Fatalf("inventory %d %s", code, data)
	}
}
