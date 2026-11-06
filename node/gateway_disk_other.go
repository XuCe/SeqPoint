//go:build !linux && !darwin

package main

func gatewayHasRoom(string) bool { return false }
