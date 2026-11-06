#!/usr/bin/env bash
set -euo pipefail
: "${HOSTED_ORIGIN:?HTTPS origin required}" "${HOSTED_STATE:?state directory required}" "${HOSTED_DATA:?Btrfs data directory required}"
[[ "$HOSTED_ORIGIN" =~ ^https://[a-zA-Z0-9.:-]+$ && "$HOSTED_STATE" = /* && "$HOSTED_DATA" = /* ]]
umask 077
token=$(openssl rand -hex 32)
slot=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
folder="$HOSTED_DATA/$slot"
mkdir -p "$HOSTED_STATE/invites"
btrfs subvolume create "$folder" >&2
btrfs qgroup limit "${HOSTED_QUOTA:-1G}" "$folder"
chown --reference="$HOSTED_DATA" "$folder"
chmod 700 "$folder"
# Publish only after the quota and permissions are in force.
touch "$HOSTED_STATE/invites/$slot"
chown --reference="$HOSTED_STATE" "$HOSTED_STATE/invites" "$HOSTED_STATE/invites/$slot"
printf '%s/invite#%s\n' "$HOSTED_ORIGIN" "$token"
