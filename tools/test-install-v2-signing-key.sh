#!/bin/bash
# Disposable test for the local PREPARE_ONLY signing-key resume path.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO=$TMP/repo
WORKSPACE=$TMP/workspace
KEYDIR=$WORKSPACE/keys/v2
TREE=$TMP/prepared/openwrt-v2
mkdir -p "$FAKE_REPO/tools" "$FAKE_REPO/keys" "$KEYDIR" "$TREE/files/etc"
cp "$REPO/tools/install-v2-signing-key.sh" "$FAKE_REPO/tools/install-v2-signing-key.sh"
touch "$TREE/files/etc/rd03v2-release" "$TREE/.config.v2-wanted"

openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/private-key.pem"
chmod 600 "$KEYDIR/private-key.pem"
openssl ec -in "$KEYDIR/private-key.pem" -pubout -out "$KEYDIR/public-key.pem" 2>/dev/null
cp "$KEYDIR/public-key.pem" "$FAKE_REPO/keys/public-key.pem"

# First call must install the validated pair with restrictive private-key permissions.
RD03V2_WS="$WORKSPACE" bash "$FAKE_REPO/tools/install-v2-signing-key.sh" "$TREE"
[ "$(stat -c %a "$TREE/private-key.pem")" = 600 ]
cmp -s "$TREE/public-key.pem" "$FAKE_REPO/keys/public-key.pem"
openssl ec -in "$TREE/private-key.pem" -pubout 2>/dev/null | cmp -s - "$FAKE_REPO/keys/public-key.pem"
first_hash=$(sha256sum "$TREE/private-key.pem" | awk '{print $1}')

# A second call must be idempotent and must not replace the existing key.
RD03V2_WS="$WORKSPACE" bash "$FAKE_REPO/tools/install-v2-signing-key.sh" "$TREE"
second_hash=$(sha256sum "$TREE/private-key.pem" | awk '{print $1}')
[ "$first_hash" = "$second_hash" ]

# A different workspace key must be rejected and must not alter the prepared tree.
BAD_KEYDIR=$TMP/bad-keys
mkdir -p "$BAD_KEYDIR"
openssl ecparam -name prime256v1 -genkey -noout -out "$BAD_KEYDIR/private-key.pem"
chmod 600 "$BAD_KEYDIR/private-key.pem"
openssl ec -in "$BAD_KEYDIR/private-key.pem" -pubout -out "$BAD_KEYDIR/public-key.pem" 2>/dev/null
if V2_KEY_DIR="$BAD_KEYDIR" RD03V2_WS="$WORKSPACE" bash "$FAKE_REPO/tools/install-v2-signing-key.sh" "$TREE" >"$TMP/mismatch.log" 2>&1; then
  echo "FAIL: mismatched workspace key was accepted" >&2
  exit 1
fi
[ "$first_hash" = "$(sha256sum "$TREE/private-key.pem" | awk '{print $1}')" ]

# A partial keypair in the build tree must fail closed instead of being overwritten.
rm "$TREE/public-key.pem"
if RD03V2_WS="$WORKSPACE" bash "$FAKE_REPO/tools/install-v2-signing-key.sh" "$TREE" >"$TMP/incomplete.log" 2>&1; then
  echo "FAIL: incomplete build-tree keypair was accepted" >&2
  exit 1
fi
[ ! -e "$TREE/public-key.pem" ]
[ "$first_hash" = "$(sha256sum "$TREE/private-key.pem" | awk '{print $1}')" ]

echo "PASS: key bootstrap, idempotence, mismatch rejection and partial-pair rejection"
