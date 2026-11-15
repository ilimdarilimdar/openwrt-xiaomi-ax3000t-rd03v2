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


# The pinned QSDK source already uses atomic_t nesting counters, but its
# read-then-decrement update is not serialized with packet-hook stop checks.
# Require stop updates and hook reads to share the family frontend lock, with a
# guarded decrement so overlapping callers cannot reopen the frontend early.
check_stop_temp_refcount() {
  local ecm_root=$1
  python3 - "$ecm_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
families = {
    "ipv4": {
        "front": root / "frontends/ecm_front_end_ipv4.c",
        "common": root / "frontends/cmn/ecm_ipv4.c",
        "header": root / "frontends/include/ecm_front_end_ipv4.h",
        "counter": "ecm_front_end_ipv4_stopped_temp",
        "stop_fn": "ecm_front_end_ipv4_stop_temp(int num)",
        "lock": "ecm_ipv4_lock",
        "prototype": "extern void ecm_front_end_ipv4_stop_temp(int num);",
    },
    "ipv6": {
        "front": root / "frontends/ecm_front_end_ipv6.c",
        "common": root / "frontends/cmn/ecm_ipv6.c",
        "header": root / "frontends/include/ecm_front_end_ipv6.h",
        "counter": "ecm_front_end_ipv6_stopped_temp",
        "stop_fn": "ecm_front_end_ipv6_stop_temp(int num)",
        "lock": "ecm_ipv6_lock",
        "prototype": "extern void ecm_front_end_ipv6_stop_temp(int num);",
    },
}

def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"FAIL: missing {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit(f"FAIL: missing function body for {signature}")
    depth = 0
    for pos in range(brace, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:pos + 1]
    raise SystemExit(f"FAIL: unterminated function {signature}")

for family, spec in families.items():
    front = spec["front"].read_text()
    common = spec["common"].read_text()
    header = spec["header"].read_text()
    counter = spec["counter"]
    lock = spec["lock"]

    declaration = f"static atomic_t {counter} = ATOMIC_INIT(0);"
    if declaration not in common:
        raise SystemExit(f"FAIL: {family} temporary-stop counter is not owned by the common frontend")
    if "#include <linux/atomic.h>" not in common:
        raise SystemExit(f"FAIL: {family} common frontend lacks linux/atomic.h")
    if counter in front:
        raise SystemExit(f"FAIL: {family} stop state is still defined in the separate frontend file")
    if f"extern atomic_t {counter};" in header or f"extern int {counter};" in header:
        raise SystemExit(f"FAIL: {family} temporary-stop counter is unnecessarily exposed in its public header")
    if spec["prototype"] not in header:
        raise SystemExit(f"FAIL: {family} stop_temp() API prototype is missing")

    body = function_body(common, spec["stop_fn"])
    lock_token = f"spin_lock_bh(&{lock});"
    unlock_token = f"spin_unlock_bh(&{lock});"
    inc_token = f"atomic_inc(&{counter});"
    dec_token = f"atomic_dec_if_positive(&{counter});"
    positions = [
        body.find(lock_token),
        body.find(inc_token),
        body.find(dec_token),
        body.find(unlock_token),
    ]
    if any(position < 0 for position in positions):
        raise SystemExit(f"FAIL: {family} stop_temp() does not take the packet-hook lock around both counter updates")
    if positions != sorted(positions):
        raise SystemExit(f"FAIL: {family} stop_temp() updates the counter outside the shared packet-hook lock")

    reads = list(re.finditer(re.escape(f"atomic_read(&{counter})"), common))
    if len(reads) != 3:
        raise SystemExit(f"FAIL: {family} packet hooks use {len(reads)} atomic reads; expected 3")
    for match in reads:
        lock_pos = common.rfind(lock_token, 0, match.start())
        unlock_pos = common.find(unlock_token, match.end())
        if lock_pos < 0 or unlock_pos < 0:
            raise SystemExit(f"FAIL: {family} packet-hook stop read is not protected by {lock}")
        if common.find(unlock_token, lock_pos, match.start()) >= 0:
            raise SystemExit(f"FAIL: {family} packet-hook stop read occurs after releasing {lock}")
    if f"unlikely({counter})" in common:
        raise SystemExit(f"FAIL: {family} has a non-atomic temporary-stop read")

print("PASS: IPv4/IPv6 temporary-stop counters are updated under packet-hook locks")
print("PASS: all six packet-hook stop reads use the same lock as stop_temp()")
PY
}
[[ -s "$MAKEFILE" ]] || die "prepared qca-nss-ecm Makefile not found: $MAKEFILE"
[[ -s "$PATCH_FILE" ]] || die "feed overlay patch not found: $PATCH_FILE"

# Validate patch envelope and every unified-diff hunk before downloading/applying source.
python3 - "$PATCH_FILE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
diff_starts = [i for i, line in enumerate(lines) if line.startswith("diff --git ")]
if not diff_starts:
    sys.exit("FAIL: patch contains no diff --git sections")
if len(diff_starts) != 9:
    sys.exit(f"FAIL: expected 9 file sections, found {len(diff_starts)}")

hunk_re = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$")
checked_hunks = 0

for n, start in enumerate(diff_starts):
    end = diff_starts[n + 1] if n + 1 < len(diff_starts) else len(lines)
    section = lines[start:end]
    match = re.fullmatch(r"diff --git a/(.+) b/(.+)", section[0])
    if not match or match.group(1) != match.group(2):
        sys.exit(f"FAIL: malformed diff --git paths at line {start + 1}")
    relpath = match.group(1)
    first_hunk = next((i for i, line in enumerate(section) if line.startswith("@@ ")), -1)
    if first_hunk < 0:
        sys.exit(f"FAIL: no hunks for {relpath}")
    metadata = section[1:first_hunk]
    old_headers = [line for line in metadata if line.startswith("--- ")]
    new_headers = [line for line in metadata if line.startswith("+++ ")]
    if len(old_headers) != 1 or len(new_headers) != 1:
        sys.exit(f"FAIL: {relpath} must have exactly one --- and one +++ header")
    if old_headers[0] != f"--- a/{relpath}" or new_headers[0] != f"+++ b/{relpath}":
        sys.exit(f"FAIL: file header paths do not match diff --git for {relpath}")
    for line in metadata:
        if line.startswith(("--- ", "+++ ", "index ")):
            continue
        sys.exit(f"FAIL: unexpected metadata line in {relpath}: {line!r}")

    i = first_hunk
    sum_delta = 0
    while i < len(section):
        header = section[i]
        hm = hunk_re.fullmatch(header)
        if not hm:
            sys.exit(f"FAIL: unexpected line outside a hunk in {relpath}: {header!r}")
        old_start = int(hm.group(1))
        old_expected = int(hm.group(2) or "1")
        new_start = int(hm.group(3))
        new_expected = int(hm.group(4) or "1")
        delta_before = sum_delta
        if old_expected == 0:
            expected_new_start = old_start + delta_before + 1
        elif new_expected == 0:
            expected_new_start = old_start + delta_before - 1
        else:
            expected_new_start = old_start + delta_before
        if new_start != expected_new_start:
            sys.exit(
                f"FAIL: {relpath} hunk coordinates inconsistent: "
                f"old {old_start},{old_expected} -> new {new_start},{new_expected}; "
                f"expected new start {expected_new_start} after prior hunks"
            )
        old_seen = new_seen = 0
        i += 1
        while old_seen < old_expected or new_seen < new_expected:
            if i >= len(section):
                sys.exit(f"FAIL: truncated hunk in {relpath}: {header}")
            line = section[i]
            if line.startswith(" "):
                old_seen += 1
                new_seen += 1
            elif line.startswith("-"):
                old_seen += 1
            elif line.startswith("+"):
                new_seen += 1
            elif line == r"\ No newline at end of file":
                pass
            else:
                sys.exit(f"FAIL: unmarked/empty line in {relpath} hunk at local line {i + 1}: {line!r}")
            if old_seen > old_expected or new_seen > new_expected:
                sys.exit(f"FAIL: hunk exceeds declared line counts in {relpath}: {header}")
            i += 1
        while i < len(section) and section[i] == r"\ No newline at end of file":
            i += 1
        sum_delta += new_expected - old_expected
        checked_hunks += 1

print(f"PASS: patch envelope has {len(diff_starts)} unique file sections")
print(f"PASS: {checked_hunks} unified-diff hunks have valid headers and exact line counts")
PY

echo "PASS: patch structure is valid before source preflight"

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
ECM_INIT="$ECM_ROOT/ecm_init.c"
ECM_DB_HEADER="$ECM_ROOT/ecm_db/ecm_db.h"
[[ -s "$ECM_INIT" ]] || die "ecm_init.c missing from pinned ECM source"
[[ -s "$ECM_DB_HEADER" ]] || die "ecm_db/ecm_db.h missing from pinned ECM source"

# Preserve a pristine copy for the full feed-series test before raw 9002 is applied.
SERIES_ROOT="$WORK/series-source"
cp -a "$ECM_ROOT" "$SERIES_ROOT"

echo "Checking patch against QSDK $QSDK_VERSION source $PKG_SOURCE_VERSION"
if ! git -C "$ECM_ROOT" apply --whitespace=error-all --check "$PATCH_FILE"; then
  echo "DIAGNOSTIC: exact source contexts for failed ECM patch application" >&2
  python3 - "$ECM_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
specs = {
    "frontends/ecm_front_end_ipv4.c": [
        "ecm_front_end_ipv4_stopped_temp", "ecm_front_end_ipv4_stop_temp",
    ],
    "frontends/ecm_front_end_ipv6.c": [
        "ecm_front_end_ipv6_stopped_temp", "ecm_front_end_ipv6_stop_temp",
    ],
    "frontends/cmn/ecm_ipv4.c": [
        "ecm_ipv4_lock", "ecm_front_end_ipv4_stopped_temp", "ecm_front_end_ipv4_stop_temp",
    ],
    "frontends/cmn/ecm_ipv6.c": [
        "ecm_ipv6_lock", "ecm_front_end_ipv6_stopped_temp", "ecm_front_end_ipv6_stop_temp",
    ],
}
for rel, terms in specs.items():
    path = root / rel
    lines = path.read_text(errors="replace").splitlines()
    print(f"===== {rel} ({len(lines)} lines) =====")
    emitted = set()
    for term in terms:
        hits = [i for i, line in enumerate(lines) if term in line]
        print(f"-- {term}: {len(hits)} occurrence(s)")
        for hit in hits:
            lo, hi = max(0, hit - 7), min(len(lines), hit + 9)
            for i in range(lo, hi):
                if i not in emitted:
                    print(f"{i + 1:5}: {lines[i]}")
                    emitted.add(i)
            print("-----")
PY
  die "patch does not apply to the pristine pinned QSDK source; inspect the context dump above"
fi
git -C "$ECM_ROOT" apply --whitespace=error-all "$PATCH_FILE"

check_stop_temp_refcount "$ECM_ROOT"

grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration is missing after patch"
grep -qF 'unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)' "$ECM_DB" ||
  die "FIB notifier teardown is missing after patch"
grep -qF 'cancel_work_sync(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "notifier workqueue teardown is missing after patch"
grep -qF 'schedule_work(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "atomic callback does not defer work"
grep -qF 'rtnl_net_lock(&init_net);' "$ECM_DB" ||
  die "worker does not wait for the RTNL-protected rule update to finish"
grep -qF 'rtnl_net_unlock(&init_net);' "$ECM_DB" ||
  die "worker does not release RTNL before walking the ECM database"
grep -qF '#include <linux/netdevice.h>' "$ECM_DB" ||
  die "ECM DB does not include the synchronize_net() declaration"
grep -qF 'synchronize_net();' "$ECM_DB" ||
  die "FIB worker does not drain pre-existing network readers"
grep -qF "Rule ADD/DEL callbacks run inside init_net's per-net RTNL update." "$ECM_DB" ||
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
    "rtnl_net_lock(&init_net);",
    "ipv4_pending = test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4",
    "ipv6_pending = test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV6",
    "rtnl_net_unlock(&init_net);",
    "any_pending = ipv4_pending;",
    "any_pending |= ipv6_pending;",
    "if (ipv4_pending)",
    "ecm_front_end_ipv4_stop_temp(1)",
    "if (ipv6_pending)",
    "ecm_front_end_ipv6_stop_temp(1)",
    "if (any_pending)",
    "synchronize_net();",
    "if (ipv4_pending)",
    "ecm_db_connection_defunct_ip_version(4)",
    "ecm_front_end_ipv4_stop_temp(0)",
    "if (ipv6_pending)",
    "ecm_db_connection_defunct_ip_version(6)",
    "ecm_front_end_ipv6_stop_temp(0)",
]
positions = []
offset = 0
for token in ordered:
    position = worker.find(token, offset)
    if position < 0:
        sys.exit(f"FAIL: required worker sequence element is missing: {token}")
    positions.append(position)
    offset = position + len(token)
if positions != sorted(positions):
    sys.exit("FAIL: worker must drain all in-flight Netfilter hooks before defuncting ECM DB entries")
print("PASS: pending-bit snapshot is atomic with respect to RTNL rule updates")
print("PASS: frontend stop gates close before synchronize_net() and DB walk")
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
grep -qF 'DEBUG_TRACE("FIB rule update: defunct all IPv4 connections\n");' "$ECM_DB" ||
  die "IPv4 worker diagnostic string is malformed"
grep -qF 'DEBUG_TRACE("FIB rule update: defunct all IPv6 connections\n");' "$ECM_DB" ||
  die "IPv6 worker diagnostic string is malformed"
grep -qF 'ecm_front_end_ipv4_stop_temp(1)' "$ECM_DB" ||
  die "v2 IPv4 temporary stop helper is not used"
grep -qF 'ecm_front_end_ipv4_stop_temp(0)' "$ECM_DB" ||
  die "v2 IPv4 temporary start helper is not used"
grep -qF 'ecm_front_end_ipv6_stop_temp(1)' "$ECM_DB" ||
  die "v2 IPv6 temporary stop helper is not used"
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

# Also reproduce OpenWrt's real quilt patch order. The NSS feed package uses
# include/quilt.mk: without a patches/series file, files are copied in lexical
# order (ls | sort). Verify that 9002 applies after every pinned feed patch
# and our earlier 9001 patch, not only against the pristine source archive.
PATCH_DIR=$(dirname "$PATCH_FILE")
mapfile -t FEED_PATCHES < <(cd "$PATCH_DIR" && LC_ALL=C ls | LC_ALL=C sort)
series_count=0
found_9001=0
for patch_name in "${FEED_PATCHES[@]}"; do
  [[ -f "$PATCH_DIR/$patch_name" ]] || die "non-file entry in ECM patch directory: $patch_name"
  [[ "$patch_name" == "$(basename "$PATCH_FILE")" ]] && continue
  [[ "$patch_name" == 9001-rd03v2-frontends-give-both-qos-tags-a-value.patch ]] && found_9001=1
  series_count=$((series_count + 1))
  if ! patch --batch --fuzz=0 -p1 -d "$SERIES_ROOT" < "$PATCH_DIR/$patch_name" >>"$WORK/feed-series-apply.log" 2>&1; then
    cat "$WORK/feed-series-apply.log" >&2
    die "pinned ECM feed patch failed in quilt order: $patch_name"
  fi
done
[[ "$found_9001" -eq 1 ]] || die "RD03v2 ECM patch 9001 is missing from the prepared feed series"
[[ "$series_count" -gt 0 ]] || die "prepared ECM feed patch series is empty"

SERIES_ECM_DB="$SERIES_ROOT/ecm_db/ecm_db.c"
SERIES_ECM_INIT="$SERIES_ROOT/ecm_init.c"
SERIES_ECM_DB_HEADER="$SERIES_ROOT/ecm_db/ecm_db.h"
[[ -s "$SERIES_ECM_DB" ]] || die "ecm_db/ecm_db.c missing after pinned feed patches"
[[ -s "$SERIES_ECM_INIT" && -s "$SERIES_ECM_DB_HEADER" ]] || die "ecm_init.c or ecm_db/ecm_db.h missing after pinned feed patches"
git -C "$SERIES_ROOT" apply --whitespace=error-all --check "$PATCH_FILE" ||
  die "RD03v2 patch 9002 does not apply after the pinned NSS feed patch series"
git -C "$SERIES_ROOT" apply --whitespace=error-all "$PATCH_FILE"
grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$SERIES_ECM_DB" ||
  die "FIB notifier registration is missing after applying the complete feed series"
grep -qF 'ECM: policy routing rule changes defunct accelerated connections' "$SERIES_ECM_DB" ||
  die "runtime registration diagnostic is missing after applying the complete feed series"
check_stop_temp_refcount "$SERIES_ROOT"
echo "PASS: patch 9002 applies after $series_count pinned ECM feed patches, including 9001"

# ecm_db_init() must not register the new FIB notifier if its existing
# IPv4/IPv6 route-notifier registration failed. ecm_init() does not call
# ecm_db_exit() from its err_db label when ecm_db_init() returns an error.
python3 - "$ECM_DB" "$ECM_INIT" "$ECM_DB_HEADER" "$SERIES_ECM_DB" "$SERIES_ECM_INIT" "$SERIES_ECM_DB_HEADER" <<'PY'
from pathlib import Path
import re
import sys

registration = "register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)"
guard_pattern = re.compile(r"if\s*\(ret\)\s*\{\s*return\s+ret;\s*\}", re.S)

def check_source(db_path, init_path, header_path):
    db = Path(db_path).read_text()
    init = Path(init_path).read_text()
    header = Path(header_path).read_text()

    db_start = db.find("int ecm_db_init(")
    db_end = db.find("EXPORT_SYMBOL(ecm_db_init);", db_start)
    if db_start < 0 or db_end < 0:
        sys.exit(f"FAIL: ecm_db_init() missing in {db_path}")
    db_init = db[db_start:db_end]
    reg_pos = db_init.find(registration)
    if reg_pos < 0:
        sys.exit(f"FAIL: FIB notifier registration missing in {db_path}")

    route_positions = [
        db_init.find("ip_rt_register_notifier("),
        db_init.find("rt6_register_notifier("),
    ]
    route_positions = [p for p in route_positions if p >= 0]
    if not route_positions:
        sys.exit(f"FAIL: route notifier registration missing in {db_path}")
    guards = [
        m for m in guard_pattern.finditer(db_init, 0, reg_pos)
        if m.start() > max(route_positions)
    ]
    if not guards:
        sys.exit(f"FAIL: FIB registration lacks route-notifier init guard in {db_path}")

    stop_start = db.find("void ecm_db_fib_rule_notifier_stop(void)")
    stop_end = db.find("EXPORT_SYMBOL(ecm_db_fib_rule_notifier_stop);", stop_start)
    if stop_start < 0 or stop_end < 0:
        sys.exit(f"FAIL: FIB notifier stop hook missing in {db_path}")
    stop_fn = db[stop_start:stop_end]
    unregister = stop_fn.find("unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)")
    cancel = stop_fn.find("cancel_work_sync(&ecm_db_fib_rule_work)")
    if unregister < 0 or cancel < 0 or unregister > cancel:
        sys.exit(f"FAIL: stop hook must unregister before cancel_work_sync in {db_path}")
    if "void ecm_db_fib_rule_notifier_stop(void);" not in header:
        sys.exit(f"FAIL: stop-hook prototype missing in {header_path}")

    db_exit_start = db.find("void ecm_db_exit(void)")
    db_exit_end = db.find("EXPORT_SYMBOL(ecm_db_exit);", db_exit_start)
    if db_exit_start < 0 or db_exit_end < 0:
        sys.exit(f"FAIL: ecm_db_exit() missing in {db_path}")
    db_exit = db[db_exit_start:db_exit_end]
    stop_call = db_exit.find("ecm_db_fib_rule_notifier_stop();")
    terminate = db_exit.find("ecm_db_terminate_pending = true;")
    if stop_call < 0 or terminate < 0 or stop_call > terminate:
        sys.exit(f"FAIL: DB exit must stop FIB worker before DB termination in {db_path}")

    exit_start = init.find("static void __exit ecm_exit(void)")
    exit_end = init.find("module_init(ecm_init)", exit_start)
    if exit_start < 0 or exit_end < 0:
        sys.exit(f"FAIL: ecm_exit() missing in {init_path}")
    exit_fn = init[exit_start:exit_end]
    stop_call = exit_fn.find("ecm_db_fib_rule_notifier_stop();")
    conntrack = exit_fn.find("ecm_conntrack_notifier_stop(1);")
    fe_stop = exit_fn.find("ecm_front_end_ipv4_stop_temp(1);")
    fe_exit = exit_fn.find("ecm_front_end_ipv4_exit();")
    if min(stop_call, conntrack, fe_stop, fe_exit) < 0:
        sys.exit(f"FAIL: normal exit lacks lifecycle stop calls in {init_path}")
    if stop_call > min(conntrack, fe_stop, fe_exit):
        sys.exit(f"FAIL: FIB worker is not drained before normal frontend shutdown in {init_path}")

    err_ct = init.find("\nerr_ct:")
    err_v6 = init.find("\nerr_fe_ipv6:", err_ct)
    err_v4 = init.find("\nerr_fe_ipv4:", err_ct)
    err_bond = init.find("\nerr_bond:", err_v4)
    if min(err_ct, err_v6, err_v4, err_bond) < 0:
        sys.exit(f"FAIL: init unwind labels missing in {init_path}")
    checks = [
        (init[err_ct:err_v6], "ecm_front_end_ipv6_exit();", "IPv6 frontend"),
        (init[err_v6:err_v4], "ecm_front_end_ipv4_exit();", "IPv4 frontend"),
        (init[err_v4:err_bond], "ecm_front_end_bond_notifier_exit();", "bond frontend"),
    ]
    for block, target, name in checks:
        stop = block.find("ecm_db_fib_rule_notifier_stop();")
        teardown = block.find(target)
        if stop < 0 or teardown < 0 or stop > teardown:
            sys.exit(f"FAIL: FIB work is not drained before {name} teardown in {init_path}")

    print(f"PASS: FIB notifier init/unwind/normal-exit ordering ({db_path})")

check_source(*sys.argv[1:4])
check_source(*sys.argv[4:7])
print("PASS: FIB worker is drained before front-end teardown")
PY

echo "PASS: patch applies cleanly to the hash-verified pinned ECM source"
