package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
)

// ipRegions 用本地 ip2region xdb 数据库把 IP 解析成地区，不调用任何外部服务。
// 数据文件缺失时只返回 IP，不影响同步。
type ipRegions struct{ v4, v6 *xdbTable }

// xdbTable 是 ip2region xdb（结构版本 2/3）的只读内存表。
type xdbTable struct {
	data  []byte
	bytes int // 4 或 16
}

const (
	xdbHeaderBytes = 256
	xdbVectorBytes = 256 * 256 * 8
)

func loadIPRegions(directory string) ipRegions {
	var r ipRegions
	if directory == "" {
		return r
	}
	for _, name := range []string{"ip2region_v4.xdb", "ip2region_v6.xdb"} {
		data, err := os.ReadFile(filepath.Join(directory, name))
		if err != nil {
			continue
		}
		t, err := parseXdb(data)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ignore %s: %v\n", name, err)
			continue
		}
		if t.bytes == 4 {
			r.v4 = t
		} else {
			r.v6 = t
		}
	}
	return r
}

func parseXdb(data []byte) (*xdbTable, error) {
	if len(data) < xdbHeaderBytes+xdbVectorBytes {
		return nil, fmt.Errorf("truncated xdb")
	}
	t := &xdbTable{data: data, bytes: 4}
	switch binary.LittleEndian.Uint16(data) {
	case 2:
	case 3:
		switch binary.LittleEndian.Uint16(data[16:]) {
		case 4:
		case 6:
			t.bytes = 16
		default:
			return nil, fmt.Errorf("unknown ip version")
		}
	default:
		return nil, fmt.Errorf("unknown xdb structure")
	}
	return t, nil
}

// search 返回原始地区串，如 "中国|浙江省|杭州市|电信|CN"。
func (t *xdbTable) search(ip []byte) string {
	if t == nil || len(ip) != t.bytes {
		return ""
	}
	at := xdbHeaderBytes + (int(ip[0])*256+int(ip[1]))*8
	start := int(binary.LittleEndian.Uint32(t.data[at:]))
	end := int(binary.LittleEndian.Uint32(t.data[at+4:]))
	size := 2*t.bytes + 6
	if start == 0 || end < start || end+size > len(t.data) {
		return ""
	}
	// IPv4 段以小端存储，IPv6 段以大端存储。
	compare := func(stored []byte) int {
		if t.bytes == 16 {
			return bytes.Compare(ip, stored)
		}
		for i := range 4 {
			if a, b := ip[i], stored[3-i]; a != b {
				if a < b {
					return -1
				}
				return 1
			}
		}
		return 0
	}
	low, high := 0, (end-start)/size
	for low <= high {
		mid := (low + high) / 2
		p := start + mid*size
		seg := t.data[p : p+size]
		if compare(seg[:t.bytes]) < 0 {
			high = mid - 1
		} else if compare(seg[t.bytes:2*t.bytes]) > 0 {
			low = mid + 1
		} else {
			n := int(binary.LittleEndian.Uint16(seg[2*t.bytes:]))
			ptr := int(binary.LittleEndian.Uint32(seg[2*t.bytes+2:]))
			if ptr+n > len(t.data) {
				return ""
			}
			return string(t.data[ptr : ptr+n])
		}
	}
	return ""
}

// lookup 把 IP 转为界面可读的地区，如 "浙江省杭州市 · 电信"、"美国 加利福尼亚"。
func (r ipRegions) lookup(addr netip.Addr) string {
	addr = addr.Unmap()
	if !addr.IsValid() {
		return ""
	}
	if addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast() {
		return "局域网"
	}
	var raw string
	if addr.Is4() {
		b := addr.As4()
		raw = r.v4.search(b[:])
	} else {
		b := addr.As16()
		raw = r.v6.search(b[:])
	}
	return formatRegion(raw)
}

func formatRegion(raw string) string {
	var parts []string
	for _, p := range strings.Split(raw, "|") {
		p = strings.TrimSpace(p)
		if p == "" || p == "0" {
			p = ""
		}
		parts = append(parts, p)
	}
	for len(parts) < 4 {
		parts = append(parts, "")
	}
	country, province, city, isp := parts[0], parts[1], parts[2], parts[3]
	if strings.Contains(province, "内网") || strings.Contains(isp, "内网") {
		return "局域网"
	}
	place := ""
	if country != "中国" {
		place = country
	}
	if province != "" && province != country {
		place = strings.TrimSpace(place + " " + province)
	}
	if city != "" && city != province {
		if country == "中国" {
			place += city
		} else {
			place = strings.TrimSpace(place + " " + city)
		}
	}
	if place == "" {
		place = country
	}
	if isp != "" && place != "" {
		return place + " · " + isp
	}
	return place
}

// clientAddr 取请求方的出口地址。只有直连方是本机或内网反向代理时才采信转发头，
// 避免公网客户端伪造。
func clientAddr(r *http.Request) netip.Addr {
	peer, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}
	}
	addr := peer.Addr().Unmap()
	if !addr.IsLoopback() && !addr.IsPrivate() {
		return addr
	}
	if forwarded := r.Header.Values("X-Forwarded-For"); len(forwarded) > 0 {
		hops := strings.Split(forwarded[len(forwarded)-1], ",")
		if a, err := netip.ParseAddr(strings.TrimSpace(hops[len(hops)-1])); err == nil {
			return a.Unmap()
		}
	}
	if a, err := netip.ParseAddr(strings.TrimSpace(r.Header.Get("X-Real-IP"))); err == nil {
		return a.Unmap()
	}
	return addr
}
