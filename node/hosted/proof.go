package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
)

var (
	folderID = regexp.MustCompile("^seqpoint-[a-f0-9]{64}$")
	deviceID = regexp.MustCompile("^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$")
	tokenID  = regexp.MustCompile("^[a-f0-9]{64}$")
)

type enrollment struct {
	Folder, Device, PublicKey, Signature string
	Invite, Issuer, Grant                string
}

func verifies(key, signature string, fields ...string) bool {
	pub, err := base64.StdEncoding.Strict().DecodeString(key)
	if err != nil || len(pub) != ed25519.PublicKeySize || base64.StdEncoding.EncodeToString(pub) != key {
		return false
	}
	sig, err := base64.StdEncoding.Strict().DecodeString(signature)
	return err == nil && ed25519.Verify(pub, []byte(strings.Join(fields, "\n")), sig)
}

func (e enrollment) valid(origin string) bool {
	return folderID.MatchString(e.Folder) && deviceID.MatchString(e.Device) &&
		verifies(e.PublicKey, e.Signature, "seqpoint-enroll-v1", origin, e.Folder, e.Device, e.PublicKey, e.Invite, e.Issuer, e.Grant)
}

func (e enrollment) delegated(origin string, members map[string]string) bool {
	_, known := members[e.Issuer]
	return known && verifies(e.Issuer, e.Grant, "seqpoint-grant-v1", origin, e.Folder, e.PublicKey)
}

var denied = fmt.Errorf("enrollment denied")
