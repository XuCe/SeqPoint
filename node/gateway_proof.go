package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strings"
)

type gatewayClaim struct{ Folder, Device, PublicKey, Signature, Invite, Issuer, Grant string }

func gatewayKey(encoded string) (string, ed25519.PublicKey) {
	key, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(key) != ed25519.PublicKeySize || encoded != base64.StdEncoding.EncodeToString(key) {
		return "", nil
	}
	hash := sha256.Sum256(key)
	return base64.RawURLEncoding.EncodeToString(hash[:]), key
}
func gatewayVerify(key ed25519.PublicKey, signature string, fields ...string) bool {
	sig, err := base64.StdEncoding.Strict().DecodeString(signature)
	return err == nil && len(key) == ed25519.PublicKeySize && ed25519.Verify(key, []byte(strings.Join(fields, "\n")), sig)
}
func (c gatewayClaim) valid(origin string) bool {
	id, key := gatewayKey(c.PublicKey)
	return devicePattern.MatchString(c.Folder) && id != "" && id == c.Device && gatewayVerify(key, c.Signature,
		"seqpoint-gateway-enroll-v1", origin, c.Folder, c.Device, c.PublicKey, c.Invite, c.Issuer, c.Grant)
}
func (c gatewayClaim) authorized(origin string, v gatewayVault) bool {
	id, key := gatewayKey(c.Issuer)
	return id != "" && v.Devices[id] != "" && !v.Revoked[id] && gatewayVerify(key, c.Grant,
		"seqpoint-gateway-grant-v1", origin, c.Folder, c.PublicKey)
}
func ticketHash(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
