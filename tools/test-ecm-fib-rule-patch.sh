#!/usr/bin/env bash
# Verify the RD03v2 ECM FIB-rule notifier patch against the exact pinned QSDK archive.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=${TREE:-"$REPO_ROOT/openwrt-v2"}
MAKEFILE="$TREE/feeds/nss/qca-nss-ecm/Makefile"
PATCH_FILE="$TREE/feeds/nss/qca-nss-ecm/patches/9002-rd03v2-defunct-ecm-flows-on-fib-policy-rule-changes.patch"

die() {
  echo "test-ecm-fib-rule-patch: $*" >&2
  exit 1
}

[[ -s "$MAKEFILE" ]] || die "prepared qca-nss-ecm Makefile not found: $MAKEFILE"
[[ -s "$PATCH_FILE" ]] || die "feed overlay patch not found: $PATCH_FILE"

get_make_var() {
  local name=$1
  local value
  value=$(sed -n "s/^$name:=//p" "$MAKEFILE" | tail -n 1)
  [[ -n "$value" ]] || die "missing $name in $MAKEFILE"
  printf '%s' "$value"
}

PKG_NAME=$(get_make_var PKG_NAME)
PKG_SOURCE_DATE=$(get_make_var PKG_SOURCE_DATE)
PKG_SOURCE_VERSION=$(get_make_var PKG_SOURCE_VERSION)
QSDK_VERSION=$(get_make_var QSDK_VERSION)
PKG_SOURCE_URL=$(get_make_var PKG_SOURCE_URL)
PKG_HASH=$(get_make_var PKG_HASH)

[[ "$PKG_SOURCE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "unexpected PKG_SOURCE_DATE: $PKG_SOURCE_DATE"
[[ "$PKG_SOURCE_VERSION" =~ ^[0-9a-f]{40}$ ]] || die "unexpected PKG_SOURCE_VERSION: $PKG_SOURCE_VERSION"
[[ "$PKG_HASH" =~ ^[0-9a-f]{64}$ ]] || die "unexpected PKG_HASH: $PKG_HASH"

SOURCE_DATE_DOTTED=${PKG_SOURCE_DATE//-/.}
SOURCE_VERSION="$QSDK_VERSION.$SOURCE_DATE_DOTTED.$PKG_SOURCE_VERSION"
ARCHIVE="$PKG_NAME-$SOURCE_VERSION.tar.zst"
URL="$PKG_SOURCE_URL/$ARCHIVE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ARCHIVE_PATH="$WORK/$ARCHIVE"
SOURCE_DIR="$WORK/source"

mkdir -p "$SOURCE_DIR"
echo "Fetching pinned ECM source: $URL"
curl -fLsS --retry 3 --retry-delay 2 "$URL" -o "$ARCHIVE_PATH"
printf '%s  %s\n' "$PKG_HASH" "$ARCHIVE_PATH" | sha256sum -c -

tar --zstd -xf "$ARCHIVE_PATH" -C "$SOURCE_DIR"
ECM_DB=$(find "$SOURCE_DIR" -type f -path '*/ecm_db/ecm_db.c' -print -quit)
[[ -n "$ECM_DB" ]] || die "ecm_db/ecm_db.c not found in source archive"
ECM_ROOT=${ECM_DB%/ecm_db/ecm_db.c}

echo "Checking patch against QSDK $QSDK_VERSION source $PKG_SOURCE_VERSION"
git -C "$ECM_ROOT" apply --whitespace=error-all --check "$PATCH_FILE"
git -C "$ECM_ROOT" apply --whitespace=error-all "$PATCH_FILE"

grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration is missing after patch"
grep -qF 'unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)' "$ECM_DB" ||
  die "FIB notifier teardown is missing after patch"
grep -qF 'cancel_work_sync(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "notifier workqueue teardown is missing after patch"
grep -qF 'schedule_work(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "atomic callback does not defer work"
grep -qF 'rtnl_lock();' "$ECM_DB" ||
  die "worker does not wait for the RTNL-protected rule update to finish"
grep -qF 'rtnl_unlock();' "$ECM_DB" ||
  die "worker does not release RTNL before walking the ECM database"
grep -qF 'Rule ADD/DEL callbacks run inside the RTNL-protected rule update.' "$ECM_DB" ||
  die "RTNL barrier rationale is missing"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static void ecm_db_fib_rule_work_fn")
end = source.find("static DECLARE_WORK", start)
if start < 0 or end < 0:
    sys.exit("FAIL: ECM FIB-rule worker body not found")
worker = source[start:end]

ordered = [
    "rtnl_lock();",
    "ipv4_pending = test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4",
    "ipv6_pending = test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV6",
    "rtnl_unlock();",
    "if (ipv4_pending)",
    "ecm_front_end_ipv4_stop_temp(1)",
    "ecm_db_connection_defunct_ip_version(4)",
    "if (ipv6_pending)",
    "ecm_front_end_ipv6_stop_temp(1)",
    "ecm_db_connection_defunct_ip_version(6)",
]
positions = [worker.find(token) for token in ordered]
if any(position < 0 for position in positions):
    sys.exit("FAIL: RTNL snapshot or IPv4/IPv6 worker operation is missing")
if positions != sorted(positions):
    sys.exit("FAIL: pending bits must be snapshotted under RTNL, then RTNL released before the DB walk")
print("PASS: pending-bit snapshot is atomic with respect to RTNL rule updates")
PY
grep -qF 'test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4' "$ECM_DB" ||
  die "IPv4 pending-bit worker is missing"
grep -qF 'ecm_db_connection_defunct_ip_version(4)' "$ECM_DB" ||
  die "IPv4 connection defunct pass is missing"
grep -qF 'test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV6' "$ECM_DB" ||
  die "IPv6 pending-bit worker is missing"
grep -qF 'ecm_db_connection_defunct_ip_version(6)' "$ECM_DB" ||
  die "IPv6 connection defunct pass is missing"
grep -qF 'FIB_EVENT_RULE_ADD' "$ECM_DB" ||
  die "FIB_EVENT_RULE_ADD handling is missing after patch"
grep -qF 'FIB_EVENT_RULE_DEL' "$ECM_DB" ||
  die "FIB_EVENT_RULE_DEL handling is missing after patch"
grep -qF 'DEBUG_TRACE("FIB rule update: defunct all IPv4 connections\\n");' "$ECM_DB" ||
  die "IPv4 worker diagnostic string is malformed"
grep -qF 'DEBUG_TRACE("FIB rule update: defunct all IPv6 connections\\n");' "$ECM_DB" ||
  die "IPv6 worker diagnostic string is malformed"
grep -qF 'ecm_front_end_ipv4_stop_temp(1)' "$ECM_DB" ||
  die "v2 IPv4 temporary stop helper is not used"
grep -qF 'ecm_front_end_ipv4_stop_temp(0)' "$ECM_DB" ||
  die "v2 IPv4 temporary start helper is not used"
grep -qF 'ecm_front_end_ipv6_stop_temp(0)' "$ECM_DB" ||
  die "v2 IPv6 temporary start helper is not used"
grep -qF 'ECM: policy routing rule changes defunct accelerated connections' "$ECM_DB" ||
  die "runtime registration diagnostic is missing"
if grep -qF 'ret = register_fib_notifier(' "$ECM_DB"; then
  die "notifier registration return must not overwrite ecm_db_init route status"
fi
if grep -qF 'ecm_front_end_ipv4_stop(' "$ECM_DB" || grep -qF 'ecm_front_end_ipv6_stop(' "$ECM_DB"; then
  die "legacy v1 frontend stop helper was introduced"
fi

echo "PASS: patch applies cleanly to the hash-verified pinned ECM source"
