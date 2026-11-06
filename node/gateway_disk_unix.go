//go:build linux || darwin

package main

import "syscall"

func gatewayHasRoom(path string) bool {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return false
	}
	// Keep 256 MiB free even with all sixteen bounded uploads in flight.
	return uint64(st.Bavail)*uint64(st.Bsize) > 256<<20+16*maxFile
}
