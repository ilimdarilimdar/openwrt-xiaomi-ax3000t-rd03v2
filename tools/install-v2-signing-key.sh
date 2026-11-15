#!/bin/bash
# Validate and install the owner's signing key pair into a prepared v2 build tree.
# This helper is intentionally separate so the PREPARE_ONLY resume path can be tested.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WS=${RD03V2_WS:-$(dirname "$REPO")}
KEYDIR=${V2_KEY_DIR:-$WS/keys/v2}
TREE=$(cd "${1:?usage: $0 <prepared v2 tree>}" && pwd)

die() { echo "install-v2-signing-key: $*" >&2; exit 1; }

[ -f "$TREE/files/etc/rd03v2-release" ] && [ -f "$TREE/.config.v2-wanted" ] ||
  die "tree is not a prepared RD03v2 build tree"
[ -f "$REPO/keys/public-key.pem" ] || die "repository public key is missing"
[ -f "$KEYDIR/private-key.pem" ] || die "missing signing key: $KEYDIR/private-key.pem"
[ -f "$KEYDIR/public-key.pem" ] || die "missing signing public key: $KEYDIR/public-key.pem"
[ "$(stat -c %a "$KEYDIR/private-key.pem")" = 600 ] ||
  die "$KEYDIR/private-key.pem must be mode 600"

openssl ec -in "$KEYDIR/private-key.pem" -pubout 2>/dev/null | cmp -s - "$KEYDIR/public-key.pem" ||
  die "workspace public-key.pem does not match private-key.pem"
cmp -s "$KEYDIR/public-key.pem" "$REPO/keys/public-key.pem" ||
  die "workspace signing key is not the key committed in keys/public-key.pem"

# Never overwrite an existing tree key. Accept it only if it is a complete, matching pair.
if [ -e "$TREE/private-key.pem" ] || [ -e "$TREE/public-key.pem" ]; then
  [ -f "$TREE/private-key.pem" ] && [ -f "$TREE/public-key.pem" ] ||
    die "prepared tree contains an incomplete signing-key pair"
  [ "$(stat -c %a "$TREE/private-key.pem")" = 600 ] ||
    die "prepared tree private key must be mode 600"
  cmp -s "$TREE/public-key.pem" "$KEYDIR/public-key.pem" ||
    die "prepared tree public key differs from the workspace key"
  openssl ec -in "$TREE/private-key.pem" -pubout 2>/dev/null | cmp -s - "$REPO/keys/public-key.pem" ||
    die "prepared tree private key does not match the committed public key"
  echo "PASS: prepared tree signing-key pair already matches"
else
  install -m 600 "$KEYDIR/private-key.pem" "$TREE/private-key.pem"
  install -m 644 "$KEYDIR/public-key.pem" "$TREE/public-key.pem"
  echo "PASS: validated signing-key pair installed into prepared tree"
fi
