#!/usr/bin/env bash
# Verify the RD03v2 ECM FIB-rule notifier patch against the exact pinned QSDK archive.
# Includes source guards for initial-dump arming and the FIB worker drain-loop.
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

    references = []
    for source_path in root.rglob("*"):
        if source_path.suffix not in {".c", ".h"} or not source_path.is_file():
            continue
        if counter in source_path.read_text(errors="replace"):
            references.append(source_path.relative_to(root).as_posix())
    expected_reference = spec["common"].relative_to(root).as_posix()
    if references != [expected_reference]:
        raise SystemExit(
            f"FAIL: {family} temporary-stop state must have exactly one source owner "
            f"({expected_reference}); references found: {references}"
        )

print("PASS: IPv4/IPv6 temporary-stop counters are updated under packet-hook locks")
print("PASS: all six packet-hook stop reads use the same lock as stop_temp()")
PY
}
[[ -s "$MAKEFILE" ]] || die "prepared qca-nss-ecm Makefile not found: $MAKEFILE"
[[ -s "$PATCH_FILE" ]] || die "feed overlay patch not found: $PATCH_FILE"

# The current family-lock audit assumes there is no external IPsec/XFRM
# ECM notifier subscriber. The known NSS XFRM plugin registers one through
# ecm_notifier_register_connection_notify(); enabling IPsec requires a fresh
# callback/lock-order audit before this preflight may pass.
CONFIG_FILE="$TREE/.config"
IPSEC_CONFIG_RE='^(CONFIG_PACKAGE_kmod-ipsec|CONFIG_PACKAGE_kmod-ipt-ipsec|CONFIG_NSS_DRV_IPSEC_ENABLE)=(y|m)$'
[[ -s "$CONFIG_FILE" ]] || die "prepared final Kconfig not found: $CONFIG_FILE"

# Self-test the guard expression so a future edit cannot silently stop matching
# one of the Kconfig symbols or reject an explicit disabled setting.
for symbol in CONFIG_PACKAGE_kmod-ipsec CONFIG_PACKAGE_kmod-ipt-ipsec CONFIG_NSS_DRV_IPSEC_ENABLE; do
  printf '%s=m\n' "$symbol" | grep -Eq "$IPSEC_CONFIG_RE" ||
    die "IPsec/XFRM config guard does not catch $symbol=m"
done
if printf '# CONFIG_PACKAGE_kmod-ipsec is not set\n' | grep -Eq "$IPSEC_CONFIG_RE"; then
  die "IPsec/XFRM config guard incorrectly matches a disabled symbol"
fi

if grep -Eq "$IPSEC_CONFIG_RE" "$CONFIG_FILE"; then
  die "IPsec/XFRM selected: re-audit ECM external notifier callbacks and lock ordering before enabling it"
fi

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
    last_old_end = 0
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
        if old_expected and old_start <= last_old_end:
            sys.exit(
                f"FAIL: overlapping old-side hunks in {relpath}: "
                f"previous end {last_old_end}, next starts {old_start}"
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
        if old_expected:
            last_old_end = old_start + old_expected - 1
        checked_hunks += 1

print(f"PASS: patch envelope has {len(diff_starts)} unique file sections")
print(f"PASS: {checked_hunks} unified-diff hunks have valid headers and exact line counts")
PY

echo "PASS: patch structure is valid before source preflight"


# Catch direct RTNL acquisition while an ECM IPv4/IPv6 family spinlock is held.
# This is intentionally a narrow source guard, not a substitute for lockdep:
# indirect helper calls still require call-graph review and runtime testing.
# Conservatively reject direct RTNL acquisitions or RTNL precondition assertions
# anywhere in a translation unit that acquires an ECM IPv4/IPv6 family lock.
# This avoids missing alternate if/else unlock branches with a textual
# lock-to-next-unlock scan. It is still not a whole-program call-graph proof:
# indirect helpers must be reviewed and runtime lockdep remains mandatory.
check_no_rtnl_in_family_lock_translation_unit() {
  local ecm_root=$1
  python3 - "$ecm_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
family_lock = re.compile(
    r"\bspin_lock(?:_bh|_irq|_irqsave|_nested)?\s*\(\s*&ecm_ipv[46]_lock\b"
)
rtnl_operation = re.compile(
    r"\b(?:rtnl_(?:net_)?(?:lock|trylock)|"
    r"rtnl_(?:net_)?lock_(?:interruptible|killable)|"
    r"ASSERT_RTNL(?:_NET)?)\s*\("
)
violations = []

for source_path in sorted(root.rglob("*.c")):
    if not source_path.is_file():
        continue

    source = source_path.read_text(errors="replace")
    # Remove literals before comments so // inside a string is not mistaken
    # for a line comment.
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    code = re.sub(r"'/.*?'", "''", code)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    code = re.sub(r"//[^\n]*", "", code)

    if not family_lock.search(code):
        continue

    rtnl_match = rtnl_operation.search(code)
    if rtnl_match:
        line = code.count("\n", 0, rtnl_match.start()) + 1
        violations.append(f"{source_path.relative_to(root).as_posix()}:{line}")

if violations:
    raise SystemExit(
        "FAIL: direct RTNL acquisition/assertion appears in a translation unit "
        "that acquires an ECM IPv4/IPv6 family lock: " + ", ".join(violations)
    )

print(
    "PASS: no direct RTNL acquisition/assertion appears in any translation unit "
    "that acquires an ECM IPv4/IPv6 family lock"
)
PY
}


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

echo "Checking patch against QSDK $QSDK_VERSION source $PKG_SOURCE_VERSION with OpenWrt patch-kernel.sh semantics"
RAW_ROOT="$WORK/raw-patch-source"
cp -a "$ECM_ROOT" "$RAW_ROOT"
RAW_PATCH_LOG="$WORK/raw-patch-apply.log"
: > "$RAW_PATCH_LOG"
if ! ${PATCH:-patch} -f -p1 -d "$RAW_ROOT" < "$PATCH_FILE" >"$RAW_PATCH_LOG" 2>&1; then
  echo "DIAGNOSTIC: raw QSDK patch application failed with OpenWrt patch-kernel.sh semantics" >&2
  cat "$RAW_PATCH_LOG" >&2
  while IFS= read -r reject; do
    echo "===== REJECT: $reject =====" >&2
    cat "$reject" >&2
  done < <(find "$RAW_ROOT" -type f -name '*.rej' -print)
  python3 - "$RAW_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
specs = {
    "ecm_db/ecm_db.c": ["void ecm_db_exit(void)"],
    "ecm_init.c": ["static void __exit ecm_exit(void)"],
}
for rel, needles in specs.items():
    path = root / rel
    lines = path.read_text(errors="replace").splitlines()
    print(f"===== {rel} lifecycle context =====", file=sys.stderr)
    for needle in needles:
        hits = [i for i, line in enumerate(lines) if needle in line]
        print(f"{needle}: {len(hits)} match(es)", file=sys.stderr)
        for hit in hits:
            for n in range(max(0, hit - 2), min(len(lines), hit + 12)):
                print(f"{n + 1:5}: {lines[n]!r}", file=sys.stderr)
PY
  die "patch does not apply to the pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
fi
echo "PASS: 9002 applies to pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
ECM_ROOT="$RAW_ROOT"
ECM_DB="$ECM_ROOT/ecm_db/ecm_db.c"
ECM_INIT="$ECM_ROOT/ecm_init.c"
ECM_DB_HEADER="$ECM_ROOT/ecm_db/ecm_db.h"



grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration is missing after patch"
grep -qF 'unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)' "$ECM_DB" ||
  die "FIB notifier teardown is missing after patch"
grep -qF 'cancel_work_sync(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "notifier workqueue teardown is missing after patch"
grep -qF 'schedule_work(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "atomic callback does not defer work"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV4' "$ECM_DB" ||
  die "IPv4 callback-owned frontend gate state is missing"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV6' "$ECM_DB" ||
  die "IPv6 callback-owned frontend gate state is missing"
grep -qF 'if (READ_ONCE(ecm_db_fib_rule_ready))' "$ECM_DB" ||
  die "FIB callback can queue work before initial replay is complete"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, true)' "$ECM_DB" ||
  die "FIB worker is not armed after successful initial replay"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, false)' "$ECM_DB" ||
  die "FIB callback is not disarmed before notifier teardown"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static int ecm_db_fib_rule_event(")
end = source.find("static struct notifier_block ecm_db_fib_rule_nb", start)
if start < 0 or end < 0:
    sys.exit("FAIL: FIB notifier callback body not found")
callback = source[start:end]

ordered = [
    "struct fib_notifier_info *info = ptr;",
    "if (!info ||",
    "switch (info->family)",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending);",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending);",
    "if (READ_ONCE(ecm_db_fib_rule_ready))",
    "schedule_work(&ecm_db_fib_rule_work);",
]
positions = [callback.find(token) for token in ordered]
if any(position < 0 for position in positions):
    sys.exit("FAIL: callback lacks a required family-bit / deferred-work operation")
if positions != sorted(positions):
    sys.exit("FAIL: callback must classify the event and set its pending bit before queueing work")
if callback.count("schedule_work(&ecm_db_fib_rule_work);") != 1:
    sys.exit("FAIL: callback must queue one coalesced worker after family classification")

forbidden = (
    "ecm_db_connection_defunct_ip_version(",
    "synchronize_net(",
    "rtnl_net_lock(",
    "msleep(",
    "schedule_timeout(",
    "cond_resched(",
)
for token in forbidden:
    if token in callback:
        sys.exit(f"FAIL: atomic FIB callback contains process-context operation: {token}")

if callback.rfind("return NOTIFY_DONE;") < positions[-1]:
    sys.exit("FAIL: callback must return after scheduling the deferred worker")

print("PASS: FIB notifier callback records family state and queues work only after initial replay")
print("PASS: no ECM DB walk, network grace-period wait or sleepable operation runs in callback")
PY
grep -qF 'rtnl_net_lock(&init_net);' "$ECM_DB" ||
  die "worker does not wait for the RTNL-protected rule update to finish"
grep -qF 'rtnl_net_unlock(&init_net);' "$ECM_DB" ||
  die "worker does not release RTNL before walking the ECM database"
grep -qF '#include <linux/netdevice.h>' "$ECM_DB" ||
  die "ECM DB does not include the synchronize_net() declaration"
grep -qF '#include <linux/compiler.h>' "$ECM_DB" ||
  die "ECM DB does not include READ_ONCE/WRITE_ONCE definitions"
grep -qF 'synchronize_net();' "$ECM_DB" ||
  die "FIB worker does not drain pre-existing network readers"
grep -qF "Initial register_fib_notifier() replay runs under RCU without" "$ECM_DB" ||
  die "initial FIB replay / live RTNL distinction is missing"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static void ecm_db_fib_rule_work_fn")
end = source.find("static DECLARE_WORK", start)
if start < 0 or end < 0:
    sys.exit("FAIL: ECM FIB-rule worker body not found")
worker = source[start:end]

if "for (;;)" not in worker:
    sys.exit("FAIL: FIB worker does not drain pending events in a loop")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4" not in worker:
    sys.exit("FAIL: IPv4 frontend gate is not released through the gated-state bit")
if worker.count("ecm_front_end_ipv4_stop_temp(0)") != 1:
    sys.exit("FAIL: IPv4 stop gate must be released exactly once after pending work is empty")
if "rtnl_net_lock(&init_net);" not in worker or "test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4" not in worker:
    sys.exit("FAIL: worker pending snapshot is not protected by per-net RTNL")
empty_start = worker.find("if (!any_pending)")
empty_end = worker.find("return;", empty_start)
if empty_start < 0 or empty_end < 0:
    sys.exit("FAIL: worker empty-pending exit block is malformed")
empty = worker[empty_start:empty_end]
for token in ("test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4", "ecm_front_end_ipv4_stop_temp(0)", "rtnl_net_unlock(&init_net)"):
    if token not in empty:
        sys.exit(f"FAIL: IPv4 gate release is not serialized under RTNL: {token}")
if "synchronize_net();" not in worker or "ecm_db_connection_defunct_ip_version(4)" not in worker:
    sys.exit("FAIL: IPv4 defunct pass is incomplete")
if worker.find("synchronize_net();") > worker.find("ecm_db_connection_defunct_ip_version(4)"):
    sys.exit("FAIL: IPv4 DB defunct pass starts before synchronize_net()")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV6" not in empty:
    sys.exit("FAIL: IPv6 frontend gate is not released in the empty-pending branch")
if "ecm_front_end_ipv6_stop_temp(0)" not in empty:
    sys.exit("FAIL: IPv6 gate release is not serialized under RTNL")
if "#ifdef ECM_IPV6_ENABLE" not in worker:
    sys.exit("FAIL: IPv6 worker path is not conditional on ECM_IPV6_ENABLE")

print("PASS: FIB worker drains coalesced events without reopening frontend gates between passes")
print("PASS: final empty-pending check and gate release are serialized with live RTNL rule updates")
print("PASS: stop gates close in the atomic callback and release only after the final pass")
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
grep -qF 'ECM: FIB notifier registration failed' "$ECM_DB" ||
  die "FIB notifier failure diagnostic is missing"
grep -qF 'fib_ret = register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration result is not captured separately from route-notifier status"
grep -qF 'ecm_db_exit();' "$ECM_DB" ||
  die "FIB or route notifier registration failure does not tear down the initialized ECM database"
grep -qF 'return fib_ret;' "$ECM_DB" ||
  die "FIB notifier registration failure does not abort ECM module initialization"
grep -qF 'route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)' "$ECM_DB" ||
  die "IPv4 route notifier result is not captured separately"
grep -qF 'route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)' "$ECM_DB" ||
  die "IPv6 route notifier result is not captured separately"
grep -qF 'ecm_db_ipv4_route_registered = true;' "$ECM_DB" ||
  die "IPv4 route notifier registration state is not recorded"
grep -qF 'ecm_db_ipv6_route_registered = true;' "$ECM_DB" ||
  die "IPv6 route notifier registration state is not recorded"
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*ip_rt_register_notifier\(' "$ECM_DB" ||
   grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*rt6_register_notifier\(' "$ECM_DB"; then
  die "route notifier registration may overwrite the other family's failure status"
fi
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*register_fib_notifier\(' "$ECM_DB"; then
  die "notifier registration return must not overwrite ecm_db_init route status"
fi
if grep -qF 'ecm_front_end_ipv4_stop(' "$ECM_DB" || grep -qF 'ecm_front_end_ipv6_stop(' "$ECM_DB"; then
  die "legacy v1 frontend stop helper was introduced"
fi

# Reproduce OpenWrt's actual package patch path (scripts/patch-kernel.sh):
# sorted filename order, then "patch -f -p1" for every patch, including 9002.
# The raw-source git-apply check above is useful, but it is not a substitute for
# the exact patch(1) operation used by the real package build.
PATCH_DIR=$(dirname "$PATCH_FILE")
mapfile -t FEED_PATCHES < <(cd "$PATCH_DIR" && LC_ALL=C ls | LC_ALL=C sort)
series_count=0
found_9001=0
: > "$WORK/feed-series-apply.log"
for patch_name in "${FEED_PATCHES[@]}"; do
  [[ -f "$PATCH_DIR/$patch_name" ]] || die "non-file entry in ECM patch directory: $patch_name"
  [[ "$patch_name" == 9001-rd03v2-frontends-give-both-qos-tags-a-value.patch ]] && found_9001=1
  series_count=$((series_count + 1))
  if ! ${PATCH:-patch} -f -p1 -d "$SERIES_ROOT" < "$PATCH_DIR/$patch_name" >>"$WORK/feed-series-apply.log" 2>&1; then
    echo "DIAGNOSTIC: OpenWrt patch-kernel.sh-equivalent queue failed at $patch_name" >&2
    cat "$WORK/feed-series-apply.log" >&2
    while IFS= read -r reject; do
      echo "===== REJECT: $reject =====" >&2
      cat "$reject" >&2
    done < <(find "$SERIES_ROOT" -type f -name '*.rej' -print)
    die "pinned ECM patch queue failed with OpenWrt patch-kernel.sh semantics: $patch_name"
  fi
done
[[ "$found_9001" -eq 1 ]] || die "RD03v2 ECM patch 9001 is missing from the prepared feed series"
[[ "$series_count" -gt 0 ]] || die "prepared ECM feed patch series is empty"

SERIES_ECM_DB="$SERIES_ROOT/ecm_db/ecm_db.c"
SERIES_ECM_INIT="$SERIES_ROOT/ecm_init.c"
SERIES_ECM_DB_HEADER="$SERIES_ROOT/ecm_db/ecm_db.h"
[[ -s "$SERIES_ECM_DB" ]] || die "ecm_db/ecm_db.c missing after pinned feed patches"
[[ -s "$SERIES_ECM_INIT" && -s "$SERIES_ECM_DB_HEADER" ]] || die "ecm_init.c or ecm_db/ecm_db.h missing after pinned feed patches"
grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$SERIES_ECM_DB" ||
  die "FIB notifier registration is missing after applying the complete feed series"
grep -qF 'ECM: policy routing rule changes defunct accelerated connections' "$SERIES_ECM_DB" ||
  die "runtime registration diagnostic is missing after applying the complete feed series"
check_stop_temp_refcount "$SERIES_ROOT"
check_no_rtnl_in_family_lock_translation_unit "$SERIES_ROOT"
echo "PASS: complete patch queue ($series_count patches, including 9001 and 9002) applies with OpenWrt patch-kernel.sh semantics"

# ecm_db_init() must not register the FIB notifier if an existing route-notifier
# registration failed. If the FIB registration itself fails, it must call
# ecm_db_exit() internally because ecm_init() skips that cleanup at err_db.
python3 - "$ECM_DB" "$ECM_INIT" "$ECM_DB_HEADER" "$SERIES_ECM_DB" "$SERIES_ECM_INIT" "$SERIES_ECM_DB_HEADER" <<'PY'
from pathlib import Path
import re
import sys

registration = "register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)"
guard_pattern = re.compile(r"if\s*\(ret\)\s*\{\s*ecm_db_exit\(\);\s*return\s+ret;\s*\}", re.S)

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
    ready_on = db_init.find("WRITE_ONCE(ecm_db_fib_rule_ready, true)", reg_pos)
    initial_queue = db_init.find("schedule_work(&ecm_db_fib_rule_work)", ready_on)
    if ready_on < 0 or initial_queue < 0 or not (reg_pos < ready_on < initial_queue):
        sys.exit(f"FAIL: worker must be armed and queued only after register_fib_notifier() completes in {db_path}")

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
        sys.exit(f"FAIL: route/FIB registration lacks DB teardown guard in {db_path}")

    # The two route notifier results must be tracked separately. The first
    # error survives a later success or a second failure.
    if "int route_ret = 0;" not in db_init:
        sys.exit(f"FAIL: route notifier calls do not have a separate result variable in {db_path}")
    if "route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv4 notifier result is not captured in {db_path}")
    if "route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv6 notifier result is not captured in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*(?:ip_rt_register_notifier|rt6_register_notifier)\(", db_init):
        sys.exit(f"FAIL: one route notifier can overwrite the shared error state in {db_path}")
    v4_register = db_init.find("route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)")
    v4_error = db_init.find("ret = route_ret;", v4_register)
    v6_register = db_init.find("route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)")
    v6_guard = db_init.find("if (!ret) {", v6_register)
    v6_error = db_init.find("ret = route_ret;", v6_guard)
    if min(v4_register, v4_error, v6_register, v6_guard, v6_error) < 0:
        sys.exit(f"FAIL: per-family route notifier error aggregation is incomplete in {db_path}")
    if not (v4_register < v4_error < v6_register < v6_guard < v6_error):
        sys.exit(f"FAIL: IPv6 route registration can hide the earlier IPv4 notifier failure in {db_path}")
    if db_init.count("ret = route_ret;") != 2:
        sys.exit(f"FAIL: route notifier errors are not assigned exactly once per family in {db_path}")
    if "ecm_db_ipv4_route_registered = true;" not in db_init or "ecm_db_ipv6_route_registered = true;" not in db_init:
        sys.exit(f"FAIL: successful route notifier registrations are not tracked per family in {db_path}")
    for route_log in (
        r"Could not register for the IPV4 routing events error:%d\n",
        r"Could not register for the IPV6 routing events error:%d\n",
    ):
        if route_log not in db_init:
            sys.exit(f"FAIL: route notifier diagnostic string is malformed in {db_path}")
    if r"Could not register for the IPV4 routing events error:%d\\\\n" in db_init or r"Could not register for the IPV6 routing events error:%d\\\\n" in db_init:
        sys.exit(f"FAIL: route notifier diagnostic string contains a double-escaped newline in {db_path}")

    # A failed FIB notifier registration must abort module initialization,
    # tear down the fully initialized DB and preserve the route-notifier ret.
    if "fib_ret = " + registration not in db_init:
        sys.exit(f"FAIL: FIB notifier result is not stored separately in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*" + re.escape(registration), db_init):
        sys.exit(f"FAIL: FIB registration overwrites the IPv4/IPv6 route-notifier result in {db_path}")
    if "return ret;" not in db_init[reg_pos:]:
        sys.exit(f"FAIL: successful FIB registration path does not preserve route-notifier return in {db_path}")
    failure_start = db_init.find("if (fib_ret) {", reg_pos)
    failure_exit = db_init.find("ecm_db_exit();", failure_start)
    failure_return = db_init.find("return fib_ret;", failure_start)
    if min(failure_start, failure_exit, failure_return) < 0 or not (failure_start < failure_exit < failure_return):
        sys.exit(f"FAIL: FIB registration failure must tear down ECM DB before returning the error in {db_path}")
    if "ecm_db_fib_rule_notifier_fail_closed" in db:
        sys.exit(f"FAIL: obsolete frontend-gate fallback remains in {db_path}")

    # The ECM DB is initialized before packet frontends and conntrack hooks.
    # Therefore a notifier registration failure at this point can abort the
    # module without leaving existing flows from this ECM instance offloaded.
    init_start = init.find("static int __init ecm_init(void)")
    init_end = init.find("module_init(ecm_init)", init_start)
    if init_start < 0 or init_end < 0:
        sys.exit(f"FAIL: ecm_init() body not found in {init_path}")
    init_fn = init[init_start:init_end]
    db_init_pos = init_fn.find("ret = ecm_db_init(ecm_dentry);")
    ipv4_init_pos = init_fn.find("ecm_front_end_ipv4_init(ecm_dentry);")
    ct_init_pos = init_fn.find("ecm_conntrack_notifier_init(ecm_dentry);")
    if min(db_init_pos, ipv4_init_pos, ct_init_pos) < 0 or not (db_init_pos < ipv4_init_pos < ct_init_pos):
        sys.exit(f"FAIL: ECM DB must initialize before packet frontends and conntrack notifier in {init_path}")

    stop_start = db.find("void ecm_db_fib_rule_notifier_stop(void)")
    stop_end = db.find("EXPORT_SYMBOL(ecm_db_fib_rule_notifier_stop);", stop_start)
    if stop_start < 0 or stop_end < 0:
        sys.exit(f"FAIL: FIB notifier stop hook missing in {db_path}")
    stop_fn = db[stop_start:stop_end]
    ready_off = stop_fn.find("WRITE_ONCE(ecm_db_fib_rule_ready, false)")
    unregister = stop_fn.find("unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)")
    cancel = stop_fn.find("cancel_work_sync(&ecm_db_fib_rule_work)")
    if min(ready_off, unregister, cancel) < 0 or not (ready_off < unregister < cancel):
        sys.exit(f"FAIL: stop hook must disarm, unregister, then drain work in {db_path}")
    if "void ecm_db_fib_rule_notifier_stop(void);" not in header:
        sys.exit(f"FAIL: stop-hook prototype missing in {header_path}")
    for cleanup in (
        "clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(0)",
    ):
        if cleanup not in stop_fn:
            sys.exit(f"FAIL: notifier stop does not clear/release a pending gate in {db_path}: {cleanup}")

    db_exit_start = db.find("void ecm_db_exit(void)")
    db_exit_end = db.find("EXPORT_SYMBOL(ecm_db_exit);", db_exit_start)
    if db_exit_start < 0 or db_exit_end < 0:
        sys.exit(f"FAIL: ecm_db_exit() missing in {db_path}")
    db_exit = db[db_exit_start:db_exit_end]
    route_v4 = db_exit.find("if (ecm_db_ipv4_route_registered) {")
    route_v6 = db_exit.find("if (ecm_db_ipv6_route_registered) {")
    if route_v4 < 0 or route_v6 < 0:
        sys.exit(f"FAIL: DB exit does not gate route unregister by actual registration state in {db_path}")
    if "if (ecm_db_ipv4_route_enable) {" in db_exit or "if (ecm_db_ipv6_route_enable) {" in db_exit:
        sys.exit(f"FAIL: DB exit still unregisters route notifiers based only on enable flags in {db_path}")
    v4_unreg = db_exit.find("ip_rt_unregister_notifier(&ecm_db_iproute_table_update_nb)", route_v4)
    v4_clear = db_exit.find("ecm_db_ipv4_route_registered = false;", v4_unreg)
    v6_unreg = db_exit.find("rt6_unregister_notifier(&ecm_db_ip6route_table_update_nb)", route_v6)
    v6_clear = db_exit.find("ecm_db_ipv6_route_registered = false;", v6_unreg)
    if min(v4_unreg, v4_clear, v6_unreg, v6_clear) < 0 or not (route_v4 < v4_unreg < v4_clear and route_v6 < v6_unreg < v6_clear):
        sys.exit(f"FAIL: DB exit does not unregister and clear each successful route notifier in {db_path}")
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

    # Keep GNU patch fuzz from silently moving the worker drain elsewhere.
    exit_lines = exit_fn.splitlines()
    stop_lines = [
        index for index, line in enumerate(exit_lines)
        if line.strip() == "ecm_db_fib_rule_notifier_stop();"
    ]
    if len(stop_lines) != 1:
        sys.exit(f"FAIL: expected exactly one FIB worker drain call in {init_path}, found {len(stop_lines)}")
    stop_line = stop_lines[0]
    expected_next = r'DEBUG_INFO("stop conntrack notifier\n");'
    if stop_line + 1 >= len(exit_lines) or exit_lines[stop_line + 1].strip() != expected_next:
        context = "\n".join(exit_lines[max(0, stop_line - 2):min(len(exit_lines), stop_line + 4)])
        sys.exit(
            f"FAIL: FIB worker drain must immediately precede conntrack notifier shutdown in {init_path}:\n{context}"
        )

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

# The FIB notifier callback runs in atomic context. It closes the affected
# frontend gate and records the family, then queues process-context work.
# Sleeping and ECM DB defunct operations remain in the worker.
python3 - "$ECM_DB" "$SERIES_ECM_DB" <<'PY'
from pathlib import Path
import re
import sys

def check_atomic_callback(path):
    source = Path(path).read_text()
    start = source.find("static int ecm_db_fib_rule_event(")
    brace = source.find("{", start)
    end = source.find("\nstatic struct notifier_block ecm_db_fib_rule_nb", brace)
    if start < 0 or brace < 0 or end < 0:
        sys.exit(f"FAIL: FIB notifier callback is missing in {path}")
    body = source[brace + 1:end]

    required = [
        "event != FIB_EVENT_RULE_ADD",
        "event != FIB_EVENT_RULE_DEL",
        "switch (info->family)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv6_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending)",
        "READ_ONCE(ecm_db_fib_rule_ready)",
        "schedule_work(&ecm_db_fib_rule_work)",
        "return NOTIFY_DONE;",
    ]
    missing = [token for token in required if token not in body]
    if missing:
        sys.exit(f"FAIL: atomic FIB callback is missing required behavior in {path}: {missing}")

    calls = re.findall(r"\b([A-Za-z_]\w*)\s*\(", body)
    actual = [name for name in calls if name not in {"if", "switch"}]
    expected = [
        "test_and_set_bit", "ecm_front_end_ipv4_stop_temp", "set_bit",
        "test_and_set_bit", "ecm_front_end_ipv6_stop_temp", "set_bit",
        "READ_ONCE", "schedule_work",
    ]
    if actual != expected:
        sys.exit(
            f"FAIL: atomic FIB callback contains unexpected calls in {path}: {actual}; "
            "only atomic gate/set operations and deferred queueing are allowed"
        )
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4") > body.find("ecm_front_end_ipv4_stop_temp(1)") or body.find("ecm_front_end_ipv4_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4"):
        sys.exit(f"FAIL: IPv4 gate must close before its pending bit is queued in {path}")
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6") > body.find("ecm_front_end_ipv6_stop_temp(1)") or body.find("ecm_front_end_ipv6_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6"):
        sys.exit(f"FAIL: IPv6 gate must close before its pending bit is queued in {path}")
    if body.find("READ_ONCE(ecm_db_fib_rule_ready)") > body.find("schedule_work("):
        sys.exit(f"FAIL: FIB work is queued before checking initial-replay readiness in {path}")

    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv4 pending bit is set after queuing work in {path}")
    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv6 pending bit is set after queuing work in {path}")

for source_path in sys.argv[1:]:
    check_atomic_callback(source_path)

print("PASS: FIB callback closes the frontend gate atomically, records pending family, then queues deferred work")
PY

echo "PASS: patch applies cleanly to the hash-verified pinned ECM source"
 "$CONFIG_FILE"; then
  die "IPsec/XFRM selected: re-audit ECM external notifier callbacks and lock ordering before enabling it"
fi

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
    last_old_end = 0
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
        if old_expected and old_start <= last_old_end:
            sys.exit(
                f"FAIL: overlapping old-side hunks in {relpath}: "
                f"previous end {last_old_end}, next starts {old_start}"
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
        if old_expected:
            last_old_end = old_start + old_expected - 1
        checked_hunks += 1

print(f"PASS: patch envelope has {len(diff_starts)} unique file sections")
print(f"PASS: {checked_hunks} unified-diff hunks have valid headers and exact line counts")
PY

echo "PASS: patch structure is valid before source preflight"


# Catch direct RTNL acquisition while an ECM IPv4/IPv6 family spinlock is held.
# This is intentionally a narrow source guard, not a substitute for lockdep:
# indirect helper calls still require call-graph review and runtime testing.
# Conservatively reject direct RTNL acquisitions or RTNL precondition assertions
# anywhere in a translation unit that acquires an ECM IPv4/IPv6 family lock.
# This avoids missing alternate if/else unlock branches with a textual
# lock-to-next-unlock scan. It is still not a whole-program call-graph proof:
# indirect helpers must be reviewed and runtime lockdep remains mandatory.
check_no_rtnl_in_family_lock_translation_unit() {
  local ecm_root=$1
  python3 - "$ecm_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
family_lock = re.compile(
    r"\bspin_lock(?:_bh|_irq|_irqsave|_nested)?\s*\(\s*&ecm_ipv[46]_lock\b"
)
rtnl_operation = re.compile(
    r"\b(?:rtnl_(?:net_)?(?:lock|trylock)|"
    r"rtnl_(?:net_)?lock_(?:interruptible|killable)|"
    r"ASSERT_RTNL(?:_NET)?)\s*\("
)
violations = []

for source_path in sorted(root.rglob("*.c")):
    if not source_path.is_file():
        continue

    source = source_path.read_text(errors="replace")
    # Remove literals before comments so // inside a string is not mistaken
    # for a line comment.
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    code = re.sub(r"'/.*?'", "''", code)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    code = re.sub(r"//[^\n]*", "", code)

    if not family_lock.search(code):
        continue

    rtnl_match = rtnl_operation.search(code)
    if rtnl_match:
        line = code.count("\n", 0, rtnl_match.start()) + 1
        violations.append(f"{source_path.relative_to(root).as_posix()}:{line}")

if violations:
    raise SystemExit(
        "FAIL: direct RTNL acquisition/assertion appears in a translation unit "
        "that acquires an ECM IPv4/IPv6 family lock: " + ", ".join(violations)
    )

print(
    "PASS: no direct RTNL acquisition/assertion appears in any translation unit "
    "that acquires an ECM IPv4/IPv6 family lock"
)
PY
}


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

echo "Checking patch against QSDK $QSDK_VERSION source $PKG_SOURCE_VERSION with OpenWrt patch-kernel.sh semantics"
RAW_ROOT="$WORK/raw-patch-source"
cp -a "$ECM_ROOT" "$RAW_ROOT"
RAW_PATCH_LOG="$WORK/raw-patch-apply.log"
: > "$RAW_PATCH_LOG"
if ! ${PATCH:-patch} -f -p1 -d "$RAW_ROOT" < "$PATCH_FILE" >"$RAW_PATCH_LOG" 2>&1; then
  echo "DIAGNOSTIC: raw QSDK patch application failed with OpenWrt patch-kernel.sh semantics" >&2
  cat "$RAW_PATCH_LOG" >&2
  while IFS= read -r reject; do
    echo "===== REJECT: $reject =====" >&2
    cat "$reject" >&2
  done < <(find "$RAW_ROOT" -type f -name '*.rej' -print)
  python3 - "$RAW_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
specs = {
    "ecm_db/ecm_db.c": ["void ecm_db_exit(void)"],
    "ecm_init.c": ["static void __exit ecm_exit(void)"],
}
for rel, needles in specs.items():
    path = root / rel
    lines = path.read_text(errors="replace").splitlines()
    print(f"===== {rel} lifecycle context =====", file=sys.stderr)
    for needle in needles:
        hits = [i for i, line in enumerate(lines) if needle in line]
        print(f"{needle}: {len(hits)} match(es)", file=sys.stderr)
        for hit in hits:
            for n in range(max(0, hit - 2), min(len(lines), hit + 12)):
                print(f"{n + 1:5}: {lines[n]!r}", file=sys.stderr)
PY
  die "patch does not apply to the pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
fi
echo "PASS: 9002 applies to pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
ECM_ROOT="$RAW_ROOT"
ECM_DB="$ECM_ROOT/ecm_db/ecm_db.c"
ECM_INIT="$ECM_ROOT/ecm_init.c"
ECM_DB_HEADER="$ECM_ROOT/ecm_db/ecm_db.h"



grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration is missing after patch"
grep -qF 'unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)' "$ECM_DB" ||
  die "FIB notifier teardown is missing after patch"
grep -qF 'cancel_work_sync(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "notifier workqueue teardown is missing after patch"
grep -qF 'schedule_work(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "atomic callback does not defer work"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV4' "$ECM_DB" ||
  die "IPv4 callback-owned frontend gate state is missing"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV6' "$ECM_DB" ||
  die "IPv6 callback-owned frontend gate state is missing"
grep -qF 'if (READ_ONCE(ecm_db_fib_rule_ready))' "$ECM_DB" ||
  die "FIB callback can queue work before initial replay is complete"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, true)' "$ECM_DB" ||
  die "FIB worker is not armed after successful initial replay"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, false)' "$ECM_DB" ||
  die "FIB callback is not disarmed before notifier teardown"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static int ecm_db_fib_rule_event(")
end = source.find("static struct notifier_block ecm_db_fib_rule_nb", start)
if start < 0 or end < 0:
    sys.exit("FAIL: FIB notifier callback body not found")
callback = source[start:end]

ordered = [
    "struct fib_notifier_info *info = ptr;",
    "if (!info ||",
    "switch (info->family)",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending);",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending);",
    "if (READ_ONCE(ecm_db_fib_rule_ready))",
    "schedule_work(&ecm_db_fib_rule_work);",
]
positions = [callback.find(token) for token in ordered]
if any(position < 0 for position in positions):
    sys.exit("FAIL: callback lacks a required family-bit / deferred-work operation")
if positions != sorted(positions):
    sys.exit("FAIL: callback must classify the event and set its pending bit before queueing work")
if callback.count("schedule_work(&ecm_db_fib_rule_work);") != 1:
    sys.exit("FAIL: callback must queue one coalesced worker after family classification")

forbidden = (
    "ecm_db_connection_defunct_ip_version(",
    "synchronize_net(",
    "rtnl_net_lock(",
    "msleep(",
    "schedule_timeout(",
    "cond_resched(",
)
for token in forbidden:
    if token in callback:
        sys.exit(f"FAIL: atomic FIB callback contains process-context operation: {token}")

if callback.rfind("return NOTIFY_DONE;") < positions[-1]:
    sys.exit("FAIL: callback must return after scheduling the deferred worker")

print("PASS: FIB notifier callback records family state and queues work only after initial replay")
print("PASS: no ECM DB walk, network grace-period wait or sleepable operation runs in callback")
PY
grep -qF 'rtnl_net_lock(&init_net);' "$ECM_DB" ||
  die "worker does not wait for the RTNL-protected rule update to finish"
grep -qF 'rtnl_net_unlock(&init_net);' "$ECM_DB" ||
  die "worker does not release RTNL before walking the ECM database"
grep -qF '#include <linux/netdevice.h>' "$ECM_DB" ||
  die "ECM DB does not include the synchronize_net() declaration"
grep -qF '#include <linux/compiler.h>' "$ECM_DB" ||
  die "ECM DB does not include READ_ONCE/WRITE_ONCE definitions"
grep -qF 'synchronize_net();' "$ECM_DB" ||
  die "FIB worker does not drain pre-existing network readers"
grep -qF "Initial register_fib_notifier() replay runs under RCU without" "$ECM_DB" ||
  die "initial FIB replay / live RTNL distinction is missing"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static void ecm_db_fib_rule_work_fn")
end = source.find("static DECLARE_WORK", start)
if start < 0 or end < 0:
    sys.exit("FAIL: ECM FIB-rule worker body not found")
worker = source[start:end]

if "for (;;)" not in worker:
    sys.exit("FAIL: FIB worker does not drain pending events in a loop")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4" not in worker:
    sys.exit("FAIL: IPv4 frontend gate is not released through the gated-state bit")
if worker.count("ecm_front_end_ipv4_stop_temp(0)") != 1:
    sys.exit("FAIL: IPv4 stop gate must be released exactly once after pending work is empty")
if "rtnl_net_lock(&init_net);" not in worker or "test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4" not in worker:
    sys.exit("FAIL: worker pending snapshot is not protected by per-net RTNL")
empty_start = worker.find("if (!any_pending)")
empty_end = worker.find("return;", empty_start)
if empty_start < 0 or empty_end < 0:
    sys.exit("FAIL: worker empty-pending exit block is malformed")
empty = worker[empty_start:empty_end]
for token in ("test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4", "ecm_front_end_ipv4_stop_temp(0)", "rtnl_net_unlock(&init_net)"):
    if token not in empty:
        sys.exit(f"FAIL: IPv4 gate release is not serialized under RTNL: {token}")
if "synchronize_net();" not in worker or "ecm_db_connection_defunct_ip_version(4)" not in worker:
    sys.exit("FAIL: IPv4 defunct pass is incomplete")
if worker.find("synchronize_net();") > worker.find("ecm_db_connection_defunct_ip_version(4)"):
    sys.exit("FAIL: IPv4 DB defunct pass starts before synchronize_net()")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV6" not in empty:
    sys.exit("FAIL: IPv6 frontend gate is not released in the empty-pending branch")
if "ecm_front_end_ipv6_stop_temp(0)" not in empty:
    sys.exit("FAIL: IPv6 gate release is not serialized under RTNL")
if "#ifdef ECM_IPV6_ENABLE" not in worker:
    sys.exit("FAIL: IPv6 worker path is not conditional on ECM_IPV6_ENABLE")

print("PASS: FIB worker drains coalesced events without reopening frontend gates between passes")
print("PASS: final empty-pending check and gate release are serialized with live RTNL rule updates")
print("PASS: stop gates close in the atomic callback and release only after the final pass")
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
grep -qF 'ECM: FIB notifier registration failed' "$ECM_DB" ||
  die "FIB notifier failure diagnostic is missing"
grep -qF 'fib_ret = register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration result is not captured separately from route-notifier status"
grep -qF 'ecm_db_exit();' "$ECM_DB" ||
  die "FIB or route notifier registration failure does not tear down the initialized ECM database"
grep -qF 'return fib_ret;' "$ECM_DB" ||
  die "FIB notifier registration failure does not abort ECM module initialization"
grep -qF 'route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)' "$ECM_DB" ||
  die "IPv4 route notifier result is not captured separately"
grep -qF 'route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)' "$ECM_DB" ||
  die "IPv6 route notifier result is not captured separately"
grep -qF 'ecm_db_ipv4_route_registered = true;' "$ECM_DB" ||
  die "IPv4 route notifier registration state is not recorded"
grep -qF 'ecm_db_ipv6_route_registered = true;' "$ECM_DB" ||
  die "IPv6 route notifier registration state is not recorded"
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*ip_rt_register_notifier\(' "$ECM_DB" ||
   grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*rt6_register_notifier\(' "$ECM_DB"; then
  die "route notifier registration may overwrite the other family's failure status"
fi
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*register_fib_notifier\(' "$ECM_DB"; then
  die "notifier registration return must not overwrite ecm_db_init route status"
fi
if grep -qF 'ecm_front_end_ipv4_stop(' "$ECM_DB" || grep -qF 'ecm_front_end_ipv6_stop(' "$ECM_DB"; then
  die "legacy v1 frontend stop helper was introduced"
fi

# Reproduce OpenWrt's actual package patch path (scripts/patch-kernel.sh):
# sorted filename order, then "patch -f -p1" for every patch, including 9002.
# The raw-source git-apply check above is useful, but it is not a substitute for
# the exact patch(1) operation used by the real package build.
PATCH_DIR=$(dirname "$PATCH_FILE")
mapfile -t FEED_PATCHES < <(cd "$PATCH_DIR" && LC_ALL=C ls | LC_ALL=C sort)
series_count=0
found_9001=0
: > "$WORK/feed-series-apply.log"
for patch_name in "${FEED_PATCHES[@]}"; do
  [[ -f "$PATCH_DIR/$patch_name" ]] || die "non-file entry in ECM patch directory: $patch_name"
  [[ "$patch_name" == 9001-rd03v2-frontends-give-both-qos-tags-a-value.patch ]] && found_9001=1
  series_count=$((series_count + 1))
  if ! ${PATCH:-patch} -f -p1 -d "$SERIES_ROOT" < "$PATCH_DIR/$patch_name" >>"$WORK/feed-series-apply.log" 2>&1; then
    echo "DIAGNOSTIC: OpenWrt patch-kernel.sh-equivalent queue failed at $patch_name" >&2
    cat "$WORK/feed-series-apply.log" >&2
    while IFS= read -r reject; do
      echo "===== REJECT: $reject =====" >&2
      cat "$reject" >&2
    done < <(find "$SERIES_ROOT" -type f -name '*.rej' -print)
    die "pinned ECM patch queue failed with OpenWrt patch-kernel.sh semantics: $patch_name"
  fi
done
[[ "$found_9001" -eq 1 ]] || die "RD03v2 ECM patch 9001 is missing from the prepared feed series"
[[ "$series_count" -gt 0 ]] || die "prepared ECM feed patch series is empty"

SERIES_ECM_DB="$SERIES_ROOT/ecm_db/ecm_db.c"
SERIES_ECM_INIT="$SERIES_ROOT/ecm_init.c"
SERIES_ECM_DB_HEADER="$SERIES_ROOT/ecm_db/ecm_db.h"
[[ -s "$SERIES_ECM_DB" ]] || die "ecm_db/ecm_db.c missing after pinned feed patches"
[[ -s "$SERIES_ECM_INIT" && -s "$SERIES_ECM_DB_HEADER" ]] || die "ecm_init.c or ecm_db/ecm_db.h missing after pinned feed patches"
grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$SERIES_ECM_DB" ||
  die "FIB notifier registration is missing after applying the complete feed series"
grep -qF 'ECM: policy routing rule changes defunct accelerated connections' "$SERIES_ECM_DB" ||
  die "runtime registration diagnostic is missing after applying the complete feed series"
check_stop_temp_refcount "$SERIES_ROOT"
check_no_rtnl_in_family_lock_translation_unit "$SERIES_ROOT"
echo "PASS: complete patch queue ($series_count patches, including 9001 and 9002) applies with OpenWrt patch-kernel.sh semantics"

# ecm_db_init() must not register the FIB notifier if an existing route-notifier
# registration failed. If the FIB registration itself fails, it must call
# ecm_db_exit() internally because ecm_init() skips that cleanup at err_db.
python3 - "$ECM_DB" "$ECM_INIT" "$ECM_DB_HEADER" "$SERIES_ECM_DB" "$SERIES_ECM_INIT" "$SERIES_ECM_DB_HEADER" <<'PY'
from pathlib import Path
import re
import sys

registration = "register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)"
guard_pattern = re.compile(r"if\s*\(ret\)\s*\{\s*ecm_db_exit\(\);\s*return\s+ret;\s*\}", re.S)

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
    ready_on = db_init.find("WRITE_ONCE(ecm_db_fib_rule_ready, true)", reg_pos)
    initial_queue = db_init.find("schedule_work(&ecm_db_fib_rule_work)", ready_on)
    if ready_on < 0 or initial_queue < 0 or not (reg_pos < ready_on < initial_queue):
        sys.exit(f"FAIL: worker must be armed and queued only after register_fib_notifier() completes in {db_path}")

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
        sys.exit(f"FAIL: route/FIB registration lacks DB teardown guard in {db_path}")

    # The two route notifier results must be tracked separately. The first
    # error survives a later success or a second failure.
    if "int route_ret = 0;" not in db_init:
        sys.exit(f"FAIL: route notifier calls do not have a separate result variable in {db_path}")
    if "route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv4 notifier result is not captured in {db_path}")
    if "route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv6 notifier result is not captured in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*(?:ip_rt_register_notifier|rt6_register_notifier)\(", db_init):
        sys.exit(f"FAIL: one route notifier can overwrite the shared error state in {db_path}")
    v4_register = db_init.find("route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)")
    v4_error = db_init.find("ret = route_ret;", v4_register)
    v6_register = db_init.find("route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)")
    v6_guard = db_init.find("if (!ret) {", v6_register)
    v6_error = db_init.find("ret = route_ret;", v6_guard)
    if min(v4_register, v4_error, v6_register, v6_guard, v6_error) < 0:
        sys.exit(f"FAIL: per-family route notifier error aggregation is incomplete in {db_path}")
    if not (v4_register < v4_error < v6_register < v6_guard < v6_error):
        sys.exit(f"FAIL: IPv6 route registration can hide the earlier IPv4 notifier failure in {db_path}")
    if db_init.count("ret = route_ret;") != 2:
        sys.exit(f"FAIL: route notifier errors are not assigned exactly once per family in {db_path}")
    if "ecm_db_ipv4_route_registered = true;" not in db_init or "ecm_db_ipv6_route_registered = true;" not in db_init:
        sys.exit(f"FAIL: successful route notifier registrations are not tracked per family in {db_path}")
    for route_log in (
        r"Could not register for the IPV4 routing events error:%d\n",
        r"Could not register for the IPV6 routing events error:%d\n",
    ):
        if route_log not in db_init:
            sys.exit(f"FAIL: route notifier diagnostic string is malformed in {db_path}")
    if r"Could not register for the IPV4 routing events error:%d\\\\n" in db_init or r"Could not register for the IPV6 routing events error:%d\\\\n" in db_init:
        sys.exit(f"FAIL: route notifier diagnostic string contains a double-escaped newline in {db_path}")

    # A failed FIB notifier registration must abort module initialization,
    # tear down the fully initialized DB and preserve the route-notifier ret.
    if "fib_ret = " + registration not in db_init:
        sys.exit(f"FAIL: FIB notifier result is not stored separately in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*" + re.escape(registration), db_init):
        sys.exit(f"FAIL: FIB registration overwrites the IPv4/IPv6 route-notifier result in {db_path}")
    if "return ret;" not in db_init[reg_pos:]:
        sys.exit(f"FAIL: successful FIB registration path does not preserve route-notifier return in {db_path}")
    failure_start = db_init.find("if (fib_ret) {", reg_pos)
    failure_exit = db_init.find("ecm_db_exit();", failure_start)
    failure_return = db_init.find("return fib_ret;", failure_start)
    if min(failure_start, failure_exit, failure_return) < 0 or not (failure_start < failure_exit < failure_return):
        sys.exit(f"FAIL: FIB registration failure must tear down ECM DB before returning the error in {db_path}")
    if "ecm_db_fib_rule_notifier_fail_closed" in db:
        sys.exit(f"FAIL: obsolete frontend-gate fallback remains in {db_path}")

    # The ECM DB is initialized before packet frontends and conntrack hooks.
    # Therefore a notifier registration failure at this point can abort the
    # module without leaving existing flows from this ECM instance offloaded.
    init_start = init.find("static int __init ecm_init(void)")
    init_end = init.find("module_init(ecm_init)", init_start)
    if init_start < 0 or init_end < 0:
        sys.exit(f"FAIL: ecm_init() body not found in {init_path}")
    init_fn = init[init_start:init_end]
    db_init_pos = init_fn.find("ret = ecm_db_init(ecm_dentry);")
    ipv4_init_pos = init_fn.find("ecm_front_end_ipv4_init(ecm_dentry);")
    ct_init_pos = init_fn.find("ecm_conntrack_notifier_init(ecm_dentry);")
    if min(db_init_pos, ipv4_init_pos, ct_init_pos) < 0 or not (db_init_pos < ipv4_init_pos < ct_init_pos):
        sys.exit(f"FAIL: ECM DB must initialize before packet frontends and conntrack notifier in {init_path}")

    stop_start = db.find("void ecm_db_fib_rule_notifier_stop(void)")
    stop_end = db.find("EXPORT_SYMBOL(ecm_db_fib_rule_notifier_stop);", stop_start)
    if stop_start < 0 or stop_end < 0:
        sys.exit(f"FAIL: FIB notifier stop hook missing in {db_path}")
    stop_fn = db[stop_start:stop_end]
    ready_off = stop_fn.find("WRITE_ONCE(ecm_db_fib_rule_ready, false)")
    unregister = stop_fn.find("unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)")
    cancel = stop_fn.find("cancel_work_sync(&ecm_db_fib_rule_work)")
    if min(ready_off, unregister, cancel) < 0 or not (ready_off < unregister < cancel):
        sys.exit(f"FAIL: stop hook must disarm, unregister, then drain work in {db_path}")
    if "void ecm_db_fib_rule_notifier_stop(void);" not in header:
        sys.exit(f"FAIL: stop-hook prototype missing in {header_path}")
    for cleanup in (
        "clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(0)",
    ):
        if cleanup not in stop_fn:
            sys.exit(f"FAIL: notifier stop does not clear/release a pending gate in {db_path}: {cleanup}")

    db_exit_start = db.find("void ecm_db_exit(void)")
    db_exit_end = db.find("EXPORT_SYMBOL(ecm_db_exit);", db_exit_start)
    if db_exit_start < 0 or db_exit_end < 0:
        sys.exit(f"FAIL: ecm_db_exit() missing in {db_path}")
    db_exit = db[db_exit_start:db_exit_end]
    route_v4 = db_exit.find("if (ecm_db_ipv4_route_registered) {")
    route_v6 = db_exit.find("if (ecm_db_ipv6_route_registered) {")
    if route_v4 < 0 or route_v6 < 0:
        sys.exit(f"FAIL: DB exit does not gate route unregister by actual registration state in {db_path}")
    if "if (ecm_db_ipv4_route_enable) {" in db_exit or "if (ecm_db_ipv6_route_enable) {" in db_exit:
        sys.exit(f"FAIL: DB exit still unregisters route notifiers based only on enable flags in {db_path}")
    v4_unreg = db_exit.find("ip_rt_unregister_notifier(&ecm_db_iproute_table_update_nb)", route_v4)
    v4_clear = db_exit.find("ecm_db_ipv4_route_registered = false;", v4_unreg)
    v6_unreg = db_exit.find("rt6_unregister_notifier(&ecm_db_ip6route_table_update_nb)", route_v6)
    v6_clear = db_exit.find("ecm_db_ipv6_route_registered = false;", v6_unreg)
    if min(v4_unreg, v4_clear, v6_unreg, v6_clear) < 0 or not (route_v4 < v4_unreg < v4_clear and route_v6 < v6_unreg < v6_clear):
        sys.exit(f"FAIL: DB exit does not unregister and clear each successful route notifier in {db_path}")
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

    # Keep GNU patch fuzz from silently moving the worker drain elsewhere.
    exit_lines = exit_fn.splitlines()
    stop_lines = [
        index for index, line in enumerate(exit_lines)
        if line.strip() == "ecm_db_fib_rule_notifier_stop();"
    ]
    if len(stop_lines) != 1:
        sys.exit(f"FAIL: expected exactly one FIB worker drain call in {init_path}, found {len(stop_lines)}")
    stop_line = stop_lines[0]
    expected_next = r'DEBUG_INFO("stop conntrack notifier\n");'
    if stop_line + 1 >= len(exit_lines) or exit_lines[stop_line + 1].strip() != expected_next:
        context = "\n".join(exit_lines[max(0, stop_line - 2):min(len(exit_lines), stop_line + 4)])
        sys.exit(
            f"FAIL: FIB worker drain must immediately precede conntrack notifier shutdown in {init_path}:\n{context}"
        )

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

# The FIB notifier callback runs in atomic context. It closes the affected
# frontend gate and records the family, then queues process-context work.
# Sleeping and ECM DB defunct operations remain in the worker.
python3 - "$ECM_DB" "$SERIES_ECM_DB" <<'PY'
from pathlib import Path
import re
import sys

def check_atomic_callback(path):
    source = Path(path).read_text()
    start = source.find("static int ecm_db_fib_rule_event(")
    brace = source.find("{", start)
    end = source.find("\nstatic struct notifier_block ecm_db_fib_rule_nb", brace)
    if start < 0 or brace < 0 or end < 0:
        sys.exit(f"FAIL: FIB notifier callback is missing in {path}")
    body = source[brace + 1:end]

    required = [
        "event != FIB_EVENT_RULE_ADD",
        "event != FIB_EVENT_RULE_DEL",
        "switch (info->family)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv6_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending)",
        "READ_ONCE(ecm_db_fib_rule_ready)",
        "schedule_work(&ecm_db_fib_rule_work)",
        "return NOTIFY_DONE;",
    ]
    missing = [token for token in required if token not in body]
    if missing:
        sys.exit(f"FAIL: atomic FIB callback is missing required behavior in {path}: {missing}")

    calls = re.findall(r"\b([A-Za-z_]\w*)\s*\(", body)
    actual = [name for name in calls if name not in {"if", "switch"}]
    expected = [
        "test_and_set_bit", "ecm_front_end_ipv4_stop_temp", "set_bit",
        "test_and_set_bit", "ecm_front_end_ipv6_stop_temp", "set_bit",
        "READ_ONCE", "schedule_work",
    ]
    if actual != expected:
        sys.exit(
            f"FAIL: atomic FIB callback contains unexpected calls in {path}: {actual}; "
            "only atomic gate/set operations and deferred queueing are allowed"
        )
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4") > body.find("ecm_front_end_ipv4_stop_temp(1)") or body.find("ecm_front_end_ipv4_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4"):
        sys.exit(f"FAIL: IPv4 gate must close before its pending bit is queued in {path}")
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6") > body.find("ecm_front_end_ipv6_stop_temp(1)") or body.find("ecm_front_end_ipv6_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6"):
        sys.exit(f"FAIL: IPv6 gate must close before its pending bit is queued in {path}")
    if body.find("READ_ONCE(ecm_db_fib_rule_ready)") > body.find("schedule_work("):
        sys.exit(f"FAIL: FIB work is queued before checking initial-replay readiness in {path}")

    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv4 pending bit is set after queuing work in {path}")
    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv6 pending bit is set after queuing work in {path}")

for source_path in sys.argv[1:]:
    check_atomic_callback(source_path)

print("PASS: FIB callback closes the frontend gate atomically, records pending family, then queues deferred work")
PY

echo "PASS: patch applies cleanly to the hash-verified pinned ECM source"

[[ -s "$CONFIG_FILE" ]] || die "prepared final Kconfig not found: $CONFIG_FILE"

# Self-test the guard expression so a future edit cannot silently stop matching
# one of the Kconfig symbols or reject an explicit disabled setting.
for symbol in CONFIG_PACKAGE_kmod-ipsec CONFIG_PACKAGE_kmod-ipt-ipsec CONFIG_NSS_DRV_IPSEC_ENABLE; do
  printf '%s=m\n' "$symbol" | grep -Eq "$IPSEC_CONFIG_RE" ||
    die "IPsec/XFRM config guard does not catch $symbol=m"
done
if printf '# CONFIG_PACKAGE_kmod-ipsec is not set\n' | grep -Eq "$IPSEC_CONFIG_RE"; then
  die "IPsec/XFRM config guard incorrectly matches a disabled symbol"
fi

if grep -Eq "$IPSEC_CONFIG_RE" "$CONFIG_FILE"; then
  die "IPsec/XFRM selected: re-audit ECM external notifier callbacks and lock ordering before enabling it"
fi
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
    last_old_end = 0
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
        if old_expected and old_start <= last_old_end:
            sys.exit(
                f"FAIL: overlapping old-side hunks in {relpath}: "
                f"previous end {last_old_end}, next starts {old_start}"
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
        if old_expected:
            last_old_end = old_start + old_expected - 1
        checked_hunks += 1

print(f"PASS: patch envelope has {len(diff_starts)} unique file sections")
print(f"PASS: {checked_hunks} unified-diff hunks have valid headers and exact line counts")
PY

echo "PASS: patch structure is valid before source preflight"


# Catch direct RTNL acquisition while an ECM IPv4/IPv6 family spinlock is held.
# This is intentionally a narrow source guard, not a substitute for lockdep:
# indirect helper calls still require call-graph review and runtime testing.
# Conservatively reject direct RTNL acquisitions or RTNL precondition assertions
# anywhere in a translation unit that acquires an ECM IPv4/IPv6 family lock.
# This avoids missing alternate if/else unlock branches with a textual
# lock-to-next-unlock scan. It is still not a whole-program call-graph proof:
# indirect helpers must be reviewed and runtime lockdep remains mandatory.
check_no_rtnl_in_family_lock_translation_unit() {
  local ecm_root=$1
  python3 - "$ecm_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
family_lock = re.compile(
    r"\bspin_lock(?:_bh|_irq|_irqsave|_nested)?\s*\(\s*&ecm_ipv[46]_lock\b"
)
rtnl_operation = re.compile(
    r"\b(?:rtnl_(?:net_)?(?:lock|trylock)|"
    r"rtnl_(?:net_)?lock_(?:interruptible|killable)|"
    r"ASSERT_RTNL(?:_NET)?)\s*\("
)
violations = []

for source_path in sorted(root.rglob("*.c")):
    if not source_path.is_file():
        continue

    source = source_path.read_text(errors="replace")
    # Remove literals before comments so // inside a string is not mistaken
    # for a line comment.
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    code = re.sub(r"'/.*?'", "''", code)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    code = re.sub(r"//[^\n]*", "", code)

    if not family_lock.search(code):
        continue

    rtnl_match = rtnl_operation.search(code)
    if rtnl_match:
        line = code.count("\n", 0, rtnl_match.start()) + 1
        violations.append(f"{source_path.relative_to(root).as_posix()}:{line}")

if violations:
    raise SystemExit(
        "FAIL: direct RTNL acquisition/assertion appears in a translation unit "
        "that acquires an ECM IPv4/IPv6 family lock: " + ", ".join(violations)
    )

print(
    "PASS: no direct RTNL acquisition/assertion appears in any translation unit "
    "that acquires an ECM IPv4/IPv6 family lock"
)
PY
}


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

echo "Checking patch against QSDK $QSDK_VERSION source $PKG_SOURCE_VERSION with OpenWrt patch-kernel.sh semantics"
RAW_ROOT="$WORK/raw-patch-source"
cp -a "$ECM_ROOT" "$RAW_ROOT"
RAW_PATCH_LOG="$WORK/raw-patch-apply.log"
: > "$RAW_PATCH_LOG"
if ! ${PATCH:-patch} -f -p1 -d "$RAW_ROOT" < "$PATCH_FILE" >"$RAW_PATCH_LOG" 2>&1; then
  echo "DIAGNOSTIC: raw QSDK patch application failed with OpenWrt patch-kernel.sh semantics" >&2
  cat "$RAW_PATCH_LOG" >&2
  while IFS= read -r reject; do
    echo "===== REJECT: $reject =====" >&2
    cat "$reject" >&2
  done < <(find "$RAW_ROOT" -type f -name '*.rej' -print)
  python3 - "$RAW_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
specs = {
    "ecm_db/ecm_db.c": ["void ecm_db_exit(void)"],
    "ecm_init.c": ["static void __exit ecm_exit(void)"],
}
for rel, needles in specs.items():
    path = root / rel
    lines = path.read_text(errors="replace").splitlines()
    print(f"===== {rel} lifecycle context =====", file=sys.stderr)
    for needle in needles:
        hits = [i for i, line in enumerate(lines) if needle in line]
        print(f"{needle}: {len(hits)} match(es)", file=sys.stderr)
        for hit in hits:
            for n in range(max(0, hit - 2), min(len(lines), hit + 12)):
                print(f"{n + 1:5}: {lines[n]!r}", file=sys.stderr)
PY
  die "patch does not apply to the pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
fi
echo "PASS: 9002 applies to pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
ECM_ROOT="$RAW_ROOT"
ECM_DB="$ECM_ROOT/ecm_db/ecm_db.c"
ECM_INIT="$ECM_ROOT/ecm_init.c"
ECM_DB_HEADER="$ECM_ROOT/ecm_db/ecm_db.h"



grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration is missing after patch"
grep -qF 'unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)' "$ECM_DB" ||
  die "FIB notifier teardown is missing after patch"
grep -qF 'cancel_work_sync(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "notifier workqueue teardown is missing after patch"
grep -qF 'schedule_work(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "atomic callback does not defer work"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV4' "$ECM_DB" ||
  die "IPv4 callback-owned frontend gate state is missing"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV6' "$ECM_DB" ||
  die "IPv6 callback-owned frontend gate state is missing"
grep -qF 'if (READ_ONCE(ecm_db_fib_rule_ready))' "$ECM_DB" ||
  die "FIB callback can queue work before initial replay is complete"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, true)' "$ECM_DB" ||
  die "FIB worker is not armed after successful initial replay"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, false)' "$ECM_DB" ||
  die "FIB callback is not disarmed before notifier teardown"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static int ecm_db_fib_rule_event(")
end = source.find("static struct notifier_block ecm_db_fib_rule_nb", start)
if start < 0 or end < 0:
    sys.exit("FAIL: FIB notifier callback body not found")
callback = source[start:end]

ordered = [
    "struct fib_notifier_info *info = ptr;",
    "if (!info ||",
    "switch (info->family)",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending);",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending);",
    "if (READ_ONCE(ecm_db_fib_rule_ready))",
    "schedule_work(&ecm_db_fib_rule_work);",
]
positions = [callback.find(token) for token in ordered]
if any(position < 0 for position in positions):
    sys.exit("FAIL: callback lacks a required family-bit / deferred-work operation")
if positions != sorted(positions):
    sys.exit("FAIL: callback must classify the event and set its pending bit before queueing work")
if callback.count("schedule_work(&ecm_db_fib_rule_work);") != 1:
    sys.exit("FAIL: callback must queue one coalesced worker after family classification")

forbidden = (
    "ecm_db_connection_defunct_ip_version(",
    "synchronize_net(",
    "rtnl_net_lock(",
    "msleep(",
    "schedule_timeout(",
    "cond_resched(",
)
for token in forbidden:
    if token in callback:
        sys.exit(f"FAIL: atomic FIB callback contains process-context operation: {token}")

if callback.rfind("return NOTIFY_DONE;") < positions[-1]:
    sys.exit("FAIL: callback must return after scheduling the deferred worker")

print("PASS: FIB notifier callback records family state and queues work only after initial replay")
print("PASS: no ECM DB walk, network grace-period wait or sleepable operation runs in callback")
PY
grep -qF 'rtnl_net_lock(&init_net);' "$ECM_DB" ||
  die "worker does not wait for the RTNL-protected rule update to finish"
grep -qF 'rtnl_net_unlock(&init_net);' "$ECM_DB" ||
  die "worker does not release RTNL before walking the ECM database"
grep -qF '#include <linux/netdevice.h>' "$ECM_DB" ||
  die "ECM DB does not include the synchronize_net() declaration"
grep -qF '#include <linux/compiler.h>' "$ECM_DB" ||
  die "ECM DB does not include READ_ONCE/WRITE_ONCE definitions"
grep -qF 'synchronize_net();' "$ECM_DB" ||
  die "FIB worker does not drain pre-existing network readers"
grep -qF "Initial register_fib_notifier() replay runs under RCU without" "$ECM_DB" ||
  die "initial FIB replay / live RTNL distinction is missing"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static void ecm_db_fib_rule_work_fn")
end = source.find("static DECLARE_WORK", start)
if start < 0 or end < 0:
    sys.exit("FAIL: ECM FIB-rule worker body not found")
worker = source[start:end]

if "for (;;)" not in worker:
    sys.exit("FAIL: FIB worker does not drain pending events in a loop")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4" not in worker:
    sys.exit("FAIL: IPv4 frontend gate is not released through the gated-state bit")
if worker.count("ecm_front_end_ipv4_stop_temp(0)") != 1:
    sys.exit("FAIL: IPv4 stop gate must be released exactly once after pending work is empty")
if "rtnl_net_lock(&init_net);" not in worker or "test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4" not in worker:
    sys.exit("FAIL: worker pending snapshot is not protected by per-net RTNL")
empty_start = worker.find("if (!any_pending)")
empty_end = worker.find("return;", empty_start)
if empty_start < 0 or empty_end < 0:
    sys.exit("FAIL: worker empty-pending exit block is malformed")
empty = worker[empty_start:empty_end]
for token in ("test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4", "ecm_front_end_ipv4_stop_temp(0)", "rtnl_net_unlock(&init_net)"):
    if token not in empty:
        sys.exit(f"FAIL: IPv4 gate release is not serialized under RTNL: {token}")
if "synchronize_net();" not in worker or "ecm_db_connection_defunct_ip_version(4)" not in worker:
    sys.exit("FAIL: IPv4 defunct pass is incomplete")
if worker.find("synchronize_net();") > worker.find("ecm_db_connection_defunct_ip_version(4)"):
    sys.exit("FAIL: IPv4 DB defunct pass starts before synchronize_net()")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV6" not in empty:
    sys.exit("FAIL: IPv6 frontend gate is not released in the empty-pending branch")
if "ecm_front_end_ipv6_stop_temp(0)" not in empty:
    sys.exit("FAIL: IPv6 gate release is not serialized under RTNL")
if "#ifdef ECM_IPV6_ENABLE" not in worker:
    sys.exit("FAIL: IPv6 worker path is not conditional on ECM_IPV6_ENABLE")

print("PASS: FIB worker drains coalesced events without reopening frontend gates between passes")
print("PASS: final empty-pending check and gate release are serialized with live RTNL rule updates")
print("PASS: stop gates close in the atomic callback and release only after the final pass")
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
grep -qF 'ECM: FIB notifier registration failed' "$ECM_DB" ||
  die "FIB notifier failure diagnostic is missing"
grep -qF 'fib_ret = register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration result is not captured separately from route-notifier status"
grep -qF 'ecm_db_exit();' "$ECM_DB" ||
  die "FIB or route notifier registration failure does not tear down the initialized ECM database"
grep -qF 'return fib_ret;' "$ECM_DB" ||
  die "FIB notifier registration failure does not abort ECM module initialization"
grep -qF 'route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)' "$ECM_DB" ||
  die "IPv4 route notifier result is not captured separately"
grep -qF 'route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)' "$ECM_DB" ||
  die "IPv6 route notifier result is not captured separately"
grep -qF 'ecm_db_ipv4_route_registered = true;' "$ECM_DB" ||
  die "IPv4 route notifier registration state is not recorded"
grep -qF 'ecm_db_ipv6_route_registered = true;' "$ECM_DB" ||
  die "IPv6 route notifier registration state is not recorded"
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*ip_rt_register_notifier\(' "$ECM_DB" ||
   grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*rt6_register_notifier\(' "$ECM_DB"; then
  die "route notifier registration may overwrite the other family's failure status"
fi
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*register_fib_notifier\(' "$ECM_DB"; then
  die "notifier registration return must not overwrite ecm_db_init route status"
fi
if grep -qF 'ecm_front_end_ipv4_stop(' "$ECM_DB" || grep -qF 'ecm_front_end_ipv6_stop(' "$ECM_DB"; then
  die "legacy v1 frontend stop helper was introduced"
fi

# Reproduce OpenWrt's actual package patch path (scripts/patch-kernel.sh):
# sorted filename order, then "patch -f -p1" for every patch, including 9002.
# The raw-source git-apply check above is useful, but it is not a substitute for
# the exact patch(1) operation used by the real package build.
PATCH_DIR=$(dirname "$PATCH_FILE")
mapfile -t FEED_PATCHES < <(cd "$PATCH_DIR" && LC_ALL=C ls | LC_ALL=C sort)
series_count=0
found_9001=0
: > "$WORK/feed-series-apply.log"
for patch_name in "${FEED_PATCHES[@]}"; do
  [[ -f "$PATCH_DIR/$patch_name" ]] || die "non-file entry in ECM patch directory: $patch_name"
  [[ "$patch_name" == 9001-rd03v2-frontends-give-both-qos-tags-a-value.patch ]] && found_9001=1
  series_count=$((series_count + 1))
  if ! ${PATCH:-patch} -f -p1 -d "$SERIES_ROOT" < "$PATCH_DIR/$patch_name" >>"$WORK/feed-series-apply.log" 2>&1; then
    echo "DIAGNOSTIC: OpenWrt patch-kernel.sh-equivalent queue failed at $patch_name" >&2
    cat "$WORK/feed-series-apply.log" >&2
    while IFS= read -r reject; do
      echo "===== REJECT: $reject =====" >&2
      cat "$reject" >&2
    done < <(find "$SERIES_ROOT" -type f -name '*.rej' -print)
    die "pinned ECM patch queue failed with OpenWrt patch-kernel.sh semantics: $patch_name"
  fi
done
[[ "$found_9001" -eq 1 ]] || die "RD03v2 ECM patch 9001 is missing from the prepared feed series"
[[ "$series_count" -gt 0 ]] || die "prepared ECM feed patch series is empty"

SERIES_ECM_DB="$SERIES_ROOT/ecm_db/ecm_db.c"
SERIES_ECM_INIT="$SERIES_ROOT/ecm_init.c"
SERIES_ECM_DB_HEADER="$SERIES_ROOT/ecm_db/ecm_db.h"
[[ -s "$SERIES_ECM_DB" ]] || die "ecm_db/ecm_db.c missing after pinned feed patches"
[[ -s "$SERIES_ECM_INIT" && -s "$SERIES_ECM_DB_HEADER" ]] || die "ecm_init.c or ecm_db/ecm_db.h missing after pinned feed patches"
grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$SERIES_ECM_DB" ||
  die "FIB notifier registration is missing after applying the complete feed series"
grep -qF 'ECM: policy routing rule changes defunct accelerated connections' "$SERIES_ECM_DB" ||
  die "runtime registration diagnostic is missing after applying the complete feed series"
check_stop_temp_refcount "$SERIES_ROOT"
check_no_rtnl_in_family_lock_translation_unit "$SERIES_ROOT"
echo "PASS: complete patch queue ($series_count patches, including 9001 and 9002) applies with OpenWrt patch-kernel.sh semantics"

# ecm_db_init() must not register the FIB notifier if an existing route-notifier
# registration failed. If the FIB registration itself fails, it must call
# ecm_db_exit() internally because ecm_init() skips that cleanup at err_db.
python3 - "$ECM_DB" "$ECM_INIT" "$ECM_DB_HEADER" "$SERIES_ECM_DB" "$SERIES_ECM_INIT" "$SERIES_ECM_DB_HEADER" <<'PY'
from pathlib import Path
import re
import sys

registration = "register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)"
guard_pattern = re.compile(r"if\s*\(ret\)\s*\{\s*ecm_db_exit\(\);\s*return\s+ret;\s*\}", re.S)

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
    ready_on = db_init.find("WRITE_ONCE(ecm_db_fib_rule_ready, true)", reg_pos)
    initial_queue = db_init.find("schedule_work(&ecm_db_fib_rule_work)", ready_on)
    if ready_on < 0 or initial_queue < 0 or not (reg_pos < ready_on < initial_queue):
        sys.exit(f"FAIL: worker must be armed and queued only after register_fib_notifier() completes in {db_path}")

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
        sys.exit(f"FAIL: route/FIB registration lacks DB teardown guard in {db_path}")

    # The two route notifier results must be tracked separately. The first
    # error survives a later success or a second failure.
    if "int route_ret = 0;" not in db_init:
        sys.exit(f"FAIL: route notifier calls do not have a separate result variable in {db_path}")
    if "route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv4 notifier result is not captured in {db_path}")
    if "route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv6 notifier result is not captured in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*(?:ip_rt_register_notifier|rt6_register_notifier)\(", db_init):
        sys.exit(f"FAIL: one route notifier can overwrite the shared error state in {db_path}")
    v4_register = db_init.find("route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)")
    v4_error = db_init.find("ret = route_ret;", v4_register)
    v6_register = db_init.find("route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)")
    v6_guard = db_init.find("if (!ret) {", v6_register)
    v6_error = db_init.find("ret = route_ret;", v6_guard)
    if min(v4_register, v4_error, v6_register, v6_guard, v6_error) < 0:
        sys.exit(f"FAIL: per-family route notifier error aggregation is incomplete in {db_path}")
    if not (v4_register < v4_error < v6_register < v6_guard < v6_error):
        sys.exit(f"FAIL: IPv6 route registration can hide the earlier IPv4 notifier failure in {db_path}")
    if db_init.count("ret = route_ret;") != 2:
        sys.exit(f"FAIL: route notifier errors are not assigned exactly once per family in {db_path}")
    if "ecm_db_ipv4_route_registered = true;" not in db_init or "ecm_db_ipv6_route_registered = true;" not in db_init:
        sys.exit(f"FAIL: successful route notifier registrations are not tracked per family in {db_path}")
    for route_log in (
        r"Could not register for the IPV4 routing events error:%d\n",
        r"Could not register for the IPV6 routing events error:%d\n",
    ):
        if route_log not in db_init:
            sys.exit(f"FAIL: route notifier diagnostic string is malformed in {db_path}")
    if r"Could not register for the IPV4 routing events error:%d\\\\n" in db_init or r"Could not register for the IPV6 routing events error:%d\\\\n" in db_init:
        sys.exit(f"FAIL: route notifier diagnostic string contains a double-escaped newline in {db_path}")

    # A failed FIB notifier registration must abort module initialization,
    # tear down the fully initialized DB and preserve the route-notifier ret.
    if "fib_ret = " + registration not in db_init:
        sys.exit(f"FAIL: FIB notifier result is not stored separately in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*" + re.escape(registration), db_init):
        sys.exit(f"FAIL: FIB registration overwrites the IPv4/IPv6 route-notifier result in {db_path}")
    if "return ret;" not in db_init[reg_pos:]:
        sys.exit(f"FAIL: successful FIB registration path does not preserve route-notifier return in {db_path}")
    failure_start = db_init.find("if (fib_ret) {", reg_pos)
    failure_exit = db_init.find("ecm_db_exit();", failure_start)
    failure_return = db_init.find("return fib_ret;", failure_start)
    if min(failure_start, failure_exit, failure_return) < 0 or not (failure_start < failure_exit < failure_return):
        sys.exit(f"FAIL: FIB registration failure must tear down ECM DB before returning the error in {db_path}")
    if "ecm_db_fib_rule_notifier_fail_closed" in db:
        sys.exit(f"FAIL: obsolete frontend-gate fallback remains in {db_path}")

    # The ECM DB is initialized before packet frontends and conntrack hooks.
    # Therefore a notifier registration failure at this point can abort the
    # module without leaving existing flows from this ECM instance offloaded.
    init_start = init.find("static int __init ecm_init(void)")
    init_end = init.find("module_init(ecm_init)", init_start)
    if init_start < 0 or init_end < 0:
        sys.exit(f"FAIL: ecm_init() body not found in {init_path}")
    init_fn = init[init_start:init_end]
    db_init_pos = init_fn.find("ret = ecm_db_init(ecm_dentry);")
    ipv4_init_pos = init_fn.find("ecm_front_end_ipv4_init(ecm_dentry);")
    ct_init_pos = init_fn.find("ecm_conntrack_notifier_init(ecm_dentry);")
    if min(db_init_pos, ipv4_init_pos, ct_init_pos) < 0 or not (db_init_pos < ipv4_init_pos < ct_init_pos):
        sys.exit(f"FAIL: ECM DB must initialize before packet frontends and conntrack notifier in {init_path}")

    stop_start = db.find("void ecm_db_fib_rule_notifier_stop(void)")
    stop_end = db.find("EXPORT_SYMBOL(ecm_db_fib_rule_notifier_stop);", stop_start)
    if stop_start < 0 or stop_end < 0:
        sys.exit(f"FAIL: FIB notifier stop hook missing in {db_path}")
    stop_fn = db[stop_start:stop_end]
    ready_off = stop_fn.find("WRITE_ONCE(ecm_db_fib_rule_ready, false)")
    unregister = stop_fn.find("unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)")
    cancel = stop_fn.find("cancel_work_sync(&ecm_db_fib_rule_work)")
    if min(ready_off, unregister, cancel) < 0 or not (ready_off < unregister < cancel):
        sys.exit(f"FAIL: stop hook must disarm, unregister, then drain work in {db_path}")
    if "void ecm_db_fib_rule_notifier_stop(void);" not in header:
        sys.exit(f"FAIL: stop-hook prototype missing in {header_path}")
    for cleanup in (
        "clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(0)",
    ):
        if cleanup not in stop_fn:
            sys.exit(f"FAIL: notifier stop does not clear/release a pending gate in {db_path}: {cleanup}")

    db_exit_start = db.find("void ecm_db_exit(void)")
    db_exit_end = db.find("EXPORT_SYMBOL(ecm_db_exit);", db_exit_start)
    if db_exit_start < 0 or db_exit_end < 0:
        sys.exit(f"FAIL: ecm_db_exit() missing in {db_path}")
    db_exit = db[db_exit_start:db_exit_end]
    route_v4 = db_exit.find("if (ecm_db_ipv4_route_registered) {")
    route_v6 = db_exit.find("if (ecm_db_ipv6_route_registered) {")
    if route_v4 < 0 or route_v6 < 0:
        sys.exit(f"FAIL: DB exit does not gate route unregister by actual registration state in {db_path}")
    if "if (ecm_db_ipv4_route_enable) {" in db_exit or "if (ecm_db_ipv6_route_enable) {" in db_exit:
        sys.exit(f"FAIL: DB exit still unregisters route notifiers based only on enable flags in {db_path}")
    v4_unreg = db_exit.find("ip_rt_unregister_notifier(&ecm_db_iproute_table_update_nb)", route_v4)
    v4_clear = db_exit.find("ecm_db_ipv4_route_registered = false;", v4_unreg)
    v6_unreg = db_exit.find("rt6_unregister_notifier(&ecm_db_ip6route_table_update_nb)", route_v6)
    v6_clear = db_exit.find("ecm_db_ipv6_route_registered = false;", v6_unreg)
    if min(v4_unreg, v4_clear, v6_unreg, v6_clear) < 0 or not (route_v4 < v4_unreg < v4_clear and route_v6 < v6_unreg < v6_clear):
        sys.exit(f"FAIL: DB exit does not unregister and clear each successful route notifier in {db_path}")
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

    # Keep GNU patch fuzz from silently moving the worker drain elsewhere.
    exit_lines = exit_fn.splitlines()
    stop_lines = [
        index for index, line in enumerate(exit_lines)
        if line.strip() == "ecm_db_fib_rule_notifier_stop();"
    ]
    if len(stop_lines) != 1:
        sys.exit(f"FAIL: expected exactly one FIB worker drain call in {init_path}, found {len(stop_lines)}")
    stop_line = stop_lines[0]
    expected_next = r'DEBUG_INFO("stop conntrack notifier\n");'
    if stop_line + 1 >= len(exit_lines) or exit_lines[stop_line + 1].strip() != expected_next:
        context = "\n".join(exit_lines[max(0, stop_line - 2):min(len(exit_lines), stop_line + 4)])
        sys.exit(
            f"FAIL: FIB worker drain must immediately precede conntrack notifier shutdown in {init_path}:\n{context}"
        )

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

# The FIB notifier callback runs in atomic context. It closes the affected
# frontend gate and records the family, then queues process-context work.
# Sleeping and ECM DB defunct operations remain in the worker.
python3 - "$ECM_DB" "$SERIES_ECM_DB" <<'PY'
from pathlib import Path
import re
import sys

def check_atomic_callback(path):
    source = Path(path).read_text()
    start = source.find("static int ecm_db_fib_rule_event(")
    brace = source.find("{", start)
    end = source.find("\nstatic struct notifier_block ecm_db_fib_rule_nb", brace)
    if start < 0 or brace < 0 or end < 0:
        sys.exit(f"FAIL: FIB notifier callback is missing in {path}")
    body = source[brace + 1:end]

    required = [
        "event != FIB_EVENT_RULE_ADD",
        "event != FIB_EVENT_RULE_DEL",
        "switch (info->family)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv6_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending)",
        "READ_ONCE(ecm_db_fib_rule_ready)",
        "schedule_work(&ecm_db_fib_rule_work)",
        "return NOTIFY_DONE;",
    ]
    missing = [token for token in required if token not in body]
    if missing:
        sys.exit(f"FAIL: atomic FIB callback is missing required behavior in {path}: {missing}")

    calls = re.findall(r"\b([A-Za-z_]\w*)\s*\(", body)
    actual = [name for name in calls if name not in {"if", "switch"}]
    expected = [
        "test_and_set_bit", "ecm_front_end_ipv4_stop_temp", "set_bit",
        "test_and_set_bit", "ecm_front_end_ipv6_stop_temp", "set_bit",
        "READ_ONCE", "schedule_work",
    ]
    if actual != expected:
        sys.exit(
            f"FAIL: atomic FIB callback contains unexpected calls in {path}: {actual}; "
            "only atomic gate/set operations and deferred queueing are allowed"
        )
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4") > body.find("ecm_front_end_ipv4_stop_temp(1)") or body.find("ecm_front_end_ipv4_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4"):
        sys.exit(f"FAIL: IPv4 gate must close before its pending bit is queued in {path}")
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6") > body.find("ecm_front_end_ipv6_stop_temp(1)") or body.find("ecm_front_end_ipv6_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6"):
        sys.exit(f"FAIL: IPv6 gate must close before its pending bit is queued in {path}")
    if body.find("READ_ONCE(ecm_db_fib_rule_ready)") > body.find("schedule_work("):
        sys.exit(f"FAIL: FIB work is queued before checking initial-replay readiness in {path}")

    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv4 pending bit is set after queuing work in {path}")
    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv6 pending bit is set after queuing work in {path}")

for source_path in sys.argv[1:]:
    check_atomic_callback(source_path)

print("PASS: FIB callback closes the frontend gate atomically, records pending family, then queues deferred work")
PY

echo "PASS: patch applies cleanly to the hash-verified pinned ECM source"
 "$CONFIG_FILE"; then
  die "IPsec/XFRM selected: re-audit ECM external notifier callbacks and lock ordering before enabling it"
fi

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
    last_old_end = 0
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
        if old_expected and old_start <= last_old_end:
            sys.exit(
                f"FAIL: overlapping old-side hunks in {relpath}: "
                f"previous end {last_old_end}, next starts {old_start}"
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
        if old_expected:
            last_old_end = old_start + old_expected - 1
        checked_hunks += 1

print(f"PASS: patch envelope has {len(diff_starts)} unique file sections")
print(f"PASS: {checked_hunks} unified-diff hunks have valid headers and exact line counts")
PY

echo "PASS: patch structure is valid before source preflight"


# Catch direct RTNL acquisition while an ECM IPv4/IPv6 family spinlock is held.
# This is intentionally a narrow source guard, not a substitute for lockdep:
# indirect helper calls still require call-graph review and runtime testing.
# Conservatively reject direct RTNL acquisitions or RTNL precondition assertions
# anywhere in a translation unit that acquires an ECM IPv4/IPv6 family lock.
# This avoids missing alternate if/else unlock branches with a textual
# lock-to-next-unlock scan. It is still not a whole-program call-graph proof:
# indirect helpers must be reviewed and runtime lockdep remains mandatory.
check_no_rtnl_in_family_lock_translation_unit() {
  local ecm_root=$1
  python3 - "$ecm_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
family_lock = re.compile(
    r"\bspin_lock(?:_bh|_irq|_irqsave|_nested)?\s*\(\s*&ecm_ipv[46]_lock\b"
)
rtnl_operation = re.compile(
    r"\b(?:rtnl_(?:net_)?(?:lock|trylock)|"
    r"rtnl_(?:net_)?lock_(?:interruptible|killable)|"
    r"ASSERT_RTNL(?:_NET)?)\s*\("
)
violations = []

for source_path in sorted(root.rglob("*.c")):
    if not source_path.is_file():
        continue

    source = source_path.read_text(errors="replace")
    # Remove literals before comments so // inside a string is not mistaken
    # for a line comment.
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    code = re.sub(r"'/.*?'", "''", code)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    code = re.sub(r"//[^\n]*", "", code)

    if not family_lock.search(code):
        continue

    rtnl_match = rtnl_operation.search(code)
    if rtnl_match:
        line = code.count("\n", 0, rtnl_match.start()) + 1
        violations.append(f"{source_path.relative_to(root).as_posix()}:{line}")

if violations:
    raise SystemExit(
        "FAIL: direct RTNL acquisition/assertion appears in a translation unit "
        "that acquires an ECM IPv4/IPv6 family lock: " + ", ".join(violations)
    )

print(
    "PASS: no direct RTNL acquisition/assertion appears in any translation unit "
    "that acquires an ECM IPv4/IPv6 family lock"
)
PY
}


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

echo "Checking patch against QSDK $QSDK_VERSION source $PKG_SOURCE_VERSION with OpenWrt patch-kernel.sh semantics"
RAW_ROOT="$WORK/raw-patch-source"
cp -a "$ECM_ROOT" "$RAW_ROOT"
RAW_PATCH_LOG="$WORK/raw-patch-apply.log"
: > "$RAW_PATCH_LOG"
if ! ${PATCH:-patch} -f -p1 -d "$RAW_ROOT" < "$PATCH_FILE" >"$RAW_PATCH_LOG" 2>&1; then
  echo "DIAGNOSTIC: raw QSDK patch application failed with OpenWrt patch-kernel.sh semantics" >&2
  cat "$RAW_PATCH_LOG" >&2
  while IFS= read -r reject; do
    echo "===== REJECT: $reject =====" >&2
    cat "$reject" >&2
  done < <(find "$RAW_ROOT" -type f -name '*.rej' -print)
  python3 - "$RAW_ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
specs = {
    "ecm_db/ecm_db.c": ["void ecm_db_exit(void)"],
    "ecm_init.c": ["static void __exit ecm_exit(void)"],
}
for rel, needles in specs.items():
    path = root / rel
    lines = path.read_text(errors="replace").splitlines()
    print(f"===== {rel} lifecycle context =====", file=sys.stderr)
    for needle in needles:
        hits = [i for i, line in enumerate(lines) if needle in line]
        print(f"{needle}: {len(hits)} match(es)", file=sys.stderr)
        for hit in hits:
            for n in range(max(0, hit - 2), min(len(lines), hit + 12)):
                print(f"{n + 1:5}: {lines[n]!r}", file=sys.stderr)
PY
  die "patch does not apply to the pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
fi
echo "PASS: 9002 applies to pristine pinned QSDK source with OpenWrt patch-kernel.sh semantics"
ECM_ROOT="$RAW_ROOT"
ECM_DB="$ECM_ROOT/ecm_db/ecm_db.c"
ECM_INIT="$ECM_ROOT/ecm_init.c"
ECM_DB_HEADER="$ECM_ROOT/ecm_db/ecm_db.h"



grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration is missing after patch"
grep -qF 'unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)' "$ECM_DB" ||
  die "FIB notifier teardown is missing after patch"
grep -qF 'cancel_work_sync(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "notifier workqueue teardown is missing after patch"
grep -qF 'schedule_work(&ecm_db_fib_rule_work)' "$ECM_DB" ||
  die "atomic callback does not defer work"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV4' "$ECM_DB" ||
  die "IPv4 callback-owned frontend gate state is missing"
grep -qF 'ECM_DB_FIB_RULE_GATED_IPV6' "$ECM_DB" ||
  die "IPv6 callback-owned frontend gate state is missing"
grep -qF 'if (READ_ONCE(ecm_db_fib_rule_ready))' "$ECM_DB" ||
  die "FIB callback can queue work before initial replay is complete"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, true)' "$ECM_DB" ||
  die "FIB worker is not armed after successful initial replay"
grep -qF 'WRITE_ONCE(ecm_db_fib_rule_ready, false)' "$ECM_DB" ||
  die "FIB callback is not disarmed before notifier teardown"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static int ecm_db_fib_rule_event(")
end = source.find("static struct notifier_block ecm_db_fib_rule_nb", start)
if start < 0 or end < 0:
    sys.exit("FAIL: FIB notifier callback body not found")
callback = source[start:end]

ordered = [
    "struct fib_notifier_info *info = ptr;",
    "if (!info ||",
    "switch (info->family)",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending);",
    "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending);",
    "if (READ_ONCE(ecm_db_fib_rule_ready))",
    "schedule_work(&ecm_db_fib_rule_work);",
]
positions = [callback.find(token) for token in ordered]
if any(position < 0 for position in positions):
    sys.exit("FAIL: callback lacks a required family-bit / deferred-work operation")
if positions != sorted(positions):
    sys.exit("FAIL: callback must classify the event and set its pending bit before queueing work")
if callback.count("schedule_work(&ecm_db_fib_rule_work);") != 1:
    sys.exit("FAIL: callback must queue one coalesced worker after family classification")

forbidden = (
    "ecm_db_connection_defunct_ip_version(",
    "synchronize_net(",
    "rtnl_net_lock(",
    "msleep(",
    "schedule_timeout(",
    "cond_resched(",
)
for token in forbidden:
    if token in callback:
        sys.exit(f"FAIL: atomic FIB callback contains process-context operation: {token}")

if callback.rfind("return NOTIFY_DONE;") < positions[-1]:
    sys.exit("FAIL: callback must return after scheduling the deferred worker")

print("PASS: FIB notifier callback records family state and queues work only after initial replay")
print("PASS: no ECM DB walk, network grace-period wait or sleepable operation runs in callback")
PY
grep -qF 'rtnl_net_lock(&init_net);' "$ECM_DB" ||
  die "worker does not wait for the RTNL-protected rule update to finish"
grep -qF 'rtnl_net_unlock(&init_net);' "$ECM_DB" ||
  die "worker does not release RTNL before walking the ECM database"
grep -qF '#include <linux/netdevice.h>' "$ECM_DB" ||
  die "ECM DB does not include the synchronize_net() declaration"
grep -qF '#include <linux/compiler.h>' "$ECM_DB" ||
  die "ECM DB does not include READ_ONCE/WRITE_ONCE definitions"
grep -qF 'synchronize_net();' "$ECM_DB" ||
  die "FIB worker does not drain pre-existing network readers"
grep -qF "Initial register_fib_notifier() replay runs under RCU without" "$ECM_DB" ||
  die "initial FIB replay / live RTNL distinction is missing"

python3 - "$ECM_DB" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.find("static void ecm_db_fib_rule_work_fn")
end = source.find("static DECLARE_WORK", start)
if start < 0 or end < 0:
    sys.exit("FAIL: ECM FIB-rule worker body not found")
worker = source[start:end]

if "for (;;)" not in worker:
    sys.exit("FAIL: FIB worker does not drain pending events in a loop")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4" not in worker:
    sys.exit("FAIL: IPv4 frontend gate is not released through the gated-state bit")
if worker.count("ecm_front_end_ipv4_stop_temp(0)") != 1:
    sys.exit("FAIL: IPv4 stop gate must be released exactly once after pending work is empty")
if "rtnl_net_lock(&init_net);" not in worker or "test_and_clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4" not in worker:
    sys.exit("FAIL: worker pending snapshot is not protected by per-net RTNL")
empty_start = worker.find("if (!any_pending)")
empty_end = worker.find("return;", empty_start)
if empty_start < 0 or empty_end < 0:
    sys.exit("FAIL: worker empty-pending exit block is malformed")
empty = worker[empty_start:empty_end]
for token in ("test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4", "ecm_front_end_ipv4_stop_temp(0)", "rtnl_net_unlock(&init_net)"):
    if token not in empty:
        sys.exit(f"FAIL: IPv4 gate release is not serialized under RTNL: {token}")
if "synchronize_net();" not in worker or "ecm_db_connection_defunct_ip_version(4)" not in worker:
    sys.exit("FAIL: IPv4 defunct pass is incomplete")
if worker.find("synchronize_net();") > worker.find("ecm_db_connection_defunct_ip_version(4)"):
    sys.exit("FAIL: IPv4 DB defunct pass starts before synchronize_net()")
if "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV6" not in empty:
    sys.exit("FAIL: IPv6 frontend gate is not released in the empty-pending branch")
if "ecm_front_end_ipv6_stop_temp(0)" not in empty:
    sys.exit("FAIL: IPv6 gate release is not serialized under RTNL")
if "#ifdef ECM_IPV6_ENABLE" not in worker:
    sys.exit("FAIL: IPv6 worker path is not conditional on ECM_IPV6_ENABLE")

print("PASS: FIB worker drains coalesced events without reopening frontend gates between passes")
print("PASS: final empty-pending check and gate release are serialized with live RTNL rule updates")
print("PASS: stop gates close in the atomic callback and release only after the final pass")
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
grep -qF 'ECM: FIB notifier registration failed' "$ECM_DB" ||
  die "FIB notifier failure diagnostic is missing"
grep -qF 'fib_ret = register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$ECM_DB" ||
  die "FIB notifier registration result is not captured separately from route-notifier status"
grep -qF 'ecm_db_exit();' "$ECM_DB" ||
  die "FIB or route notifier registration failure does not tear down the initialized ECM database"
grep -qF 'return fib_ret;' "$ECM_DB" ||
  die "FIB notifier registration failure does not abort ECM module initialization"
grep -qF 'route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)' "$ECM_DB" ||
  die "IPv4 route notifier result is not captured separately"
grep -qF 'route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)' "$ECM_DB" ||
  die "IPv6 route notifier result is not captured separately"
grep -qF 'ecm_db_ipv4_route_registered = true;' "$ECM_DB" ||
  die "IPv4 route notifier registration state is not recorded"
grep -qF 'ecm_db_ipv6_route_registered = true;' "$ECM_DB" ||
  die "IPv6 route notifier registration state is not recorded"
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*ip_rt_register_notifier\(' "$ECM_DB" ||
   grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*rt6_register_notifier\(' "$ECM_DB"; then
  die "route notifier registration may overwrite the other family's failure status"
fi
if grep -Eq '^[[:space:]]*ret[[:space:]]*=[[:space:]]*register_fib_notifier\(' "$ECM_DB"; then
  die "notifier registration return must not overwrite ecm_db_init route status"
fi
if grep -qF 'ecm_front_end_ipv4_stop(' "$ECM_DB" || grep -qF 'ecm_front_end_ipv6_stop(' "$ECM_DB"; then
  die "legacy v1 frontend stop helper was introduced"
fi

# Reproduce OpenWrt's actual package patch path (scripts/patch-kernel.sh):
# sorted filename order, then "patch -f -p1" for every patch, including 9002.
# The raw-source git-apply check above is useful, but it is not a substitute for
# the exact patch(1) operation used by the real package build.
PATCH_DIR=$(dirname "$PATCH_FILE")
mapfile -t FEED_PATCHES < <(cd "$PATCH_DIR" && LC_ALL=C ls | LC_ALL=C sort)
series_count=0
found_9001=0
: > "$WORK/feed-series-apply.log"
for patch_name in "${FEED_PATCHES[@]}"; do
  [[ -f "$PATCH_DIR/$patch_name" ]] || die "non-file entry in ECM patch directory: $patch_name"
  [[ "$patch_name" == 9001-rd03v2-frontends-give-both-qos-tags-a-value.patch ]] && found_9001=1
  series_count=$((series_count + 1))
  if ! ${PATCH:-patch} -f -p1 -d "$SERIES_ROOT" < "$PATCH_DIR/$patch_name" >>"$WORK/feed-series-apply.log" 2>&1; then
    echo "DIAGNOSTIC: OpenWrt patch-kernel.sh-equivalent queue failed at $patch_name" >&2
    cat "$WORK/feed-series-apply.log" >&2
    while IFS= read -r reject; do
      echo "===== REJECT: $reject =====" >&2
      cat "$reject" >&2
    done < <(find "$SERIES_ROOT" -type f -name '*.rej' -print)
    die "pinned ECM patch queue failed with OpenWrt patch-kernel.sh semantics: $patch_name"
  fi
done
[[ "$found_9001" -eq 1 ]] || die "RD03v2 ECM patch 9001 is missing from the prepared feed series"
[[ "$series_count" -gt 0 ]] || die "prepared ECM feed patch series is empty"

SERIES_ECM_DB="$SERIES_ROOT/ecm_db/ecm_db.c"
SERIES_ECM_INIT="$SERIES_ROOT/ecm_init.c"
SERIES_ECM_DB_HEADER="$SERIES_ROOT/ecm_db/ecm_db.h"
[[ -s "$SERIES_ECM_DB" ]] || die "ecm_db/ecm_db.c missing after pinned feed patches"
[[ -s "$SERIES_ECM_INIT" && -s "$SERIES_ECM_DB_HEADER" ]] || die "ecm_init.c or ecm_db/ecm_db.h missing after pinned feed patches"
grep -qF 'register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)' "$SERIES_ECM_DB" ||
  die "FIB notifier registration is missing after applying the complete feed series"
grep -qF 'ECM: policy routing rule changes defunct accelerated connections' "$SERIES_ECM_DB" ||
  die "runtime registration diagnostic is missing after applying the complete feed series"
check_stop_temp_refcount "$SERIES_ROOT"
check_no_rtnl_in_family_lock_translation_unit "$SERIES_ROOT"
echo "PASS: complete patch queue ($series_count patches, including 9001 and 9002) applies with OpenWrt patch-kernel.sh semantics"

# ecm_db_init() must not register the FIB notifier if an existing route-notifier
# registration failed. If the FIB registration itself fails, it must call
# ecm_db_exit() internally because ecm_init() skips that cleanup at err_db.
python3 - "$ECM_DB" "$ECM_INIT" "$ECM_DB_HEADER" "$SERIES_ECM_DB" "$SERIES_ECM_INIT" "$SERIES_ECM_DB_HEADER" <<'PY'
from pathlib import Path
import re
import sys

registration = "register_fib_notifier(&init_net, &ecm_db_fib_rule_nb, NULL, NULL)"
guard_pattern = re.compile(r"if\s*\(ret\)\s*\{\s*ecm_db_exit\(\);\s*return\s+ret;\s*\}", re.S)

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
    ready_on = db_init.find("WRITE_ONCE(ecm_db_fib_rule_ready, true)", reg_pos)
    initial_queue = db_init.find("schedule_work(&ecm_db_fib_rule_work)", ready_on)
    if ready_on < 0 or initial_queue < 0 or not (reg_pos < ready_on < initial_queue):
        sys.exit(f"FAIL: worker must be armed and queued only after register_fib_notifier() completes in {db_path}")

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
        sys.exit(f"FAIL: route/FIB registration lacks DB teardown guard in {db_path}")

    # The two route notifier results must be tracked separately. The first
    # error survives a later success or a second failure.
    if "int route_ret = 0;" not in db_init:
        sys.exit(f"FAIL: route notifier calls do not have a separate result variable in {db_path}")
    if "route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv4 notifier result is not captured in {db_path}")
    if "route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)" not in db_init:
        sys.exit(f"FAIL: IPv6 notifier result is not captured in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*(?:ip_rt_register_notifier|rt6_register_notifier)\(", db_init):
        sys.exit(f"FAIL: one route notifier can overwrite the shared error state in {db_path}")
    v4_register = db_init.find("route_ret = ip_rt_register_notifier(&ecm_db_iproute_table_update_nb)")
    v4_error = db_init.find("ret = route_ret;", v4_register)
    v6_register = db_init.find("route_ret = rt6_register_notifier(&ecm_db_ip6route_table_update_nb)")
    v6_guard = db_init.find("if (!ret) {", v6_register)
    v6_error = db_init.find("ret = route_ret;", v6_guard)
    if min(v4_register, v4_error, v6_register, v6_guard, v6_error) < 0:
        sys.exit(f"FAIL: per-family route notifier error aggregation is incomplete in {db_path}")
    if not (v4_register < v4_error < v6_register < v6_guard < v6_error):
        sys.exit(f"FAIL: IPv6 route registration can hide the earlier IPv4 notifier failure in {db_path}")
    if db_init.count("ret = route_ret;") != 2:
        sys.exit(f"FAIL: route notifier errors are not assigned exactly once per family in {db_path}")
    if "ecm_db_ipv4_route_registered = true;" not in db_init or "ecm_db_ipv6_route_registered = true;" not in db_init:
        sys.exit(f"FAIL: successful route notifier registrations are not tracked per family in {db_path}")
    for route_log in (
        r"Could not register for the IPV4 routing events error:%d\n",
        r"Could not register for the IPV6 routing events error:%d\n",
    ):
        if route_log not in db_init:
            sys.exit(f"FAIL: route notifier diagnostic string is malformed in {db_path}")
    if r"Could not register for the IPV4 routing events error:%d\\\\n" in db_init or r"Could not register for the IPV6 routing events error:%d\\\\n" in db_init:
        sys.exit(f"FAIL: route notifier diagnostic string contains a double-escaped newline in {db_path}")

    # A failed FIB notifier registration must abort module initialization,
    # tear down the fully initialized DB and preserve the route-notifier ret.
    if "fib_ret = " + registration not in db_init:
        sys.exit(f"FAIL: FIB notifier result is not stored separately in {db_path}")
    if re.search(r"(?m)^\s*ret\s*=\s*" + re.escape(registration), db_init):
        sys.exit(f"FAIL: FIB registration overwrites the IPv4/IPv6 route-notifier result in {db_path}")
    if "return ret;" not in db_init[reg_pos:]:
        sys.exit(f"FAIL: successful FIB registration path does not preserve route-notifier return in {db_path}")
    failure_start = db_init.find("if (fib_ret) {", reg_pos)
    failure_exit = db_init.find("ecm_db_exit();", failure_start)
    failure_return = db_init.find("return fib_ret;", failure_start)
    if min(failure_start, failure_exit, failure_return) < 0 or not (failure_start < failure_exit < failure_return):
        sys.exit(f"FAIL: FIB registration failure must tear down ECM DB before returning the error in {db_path}")
    if "ecm_db_fib_rule_notifier_fail_closed" in db:
        sys.exit(f"FAIL: obsolete frontend-gate fallback remains in {db_path}")

    # The ECM DB is initialized before packet frontends and conntrack hooks.
    # Therefore a notifier registration failure at this point can abort the
    # module without leaving existing flows from this ECM instance offloaded.
    init_start = init.find("static int __init ecm_init(void)")
    init_end = init.find("module_init(ecm_init)", init_start)
    if init_start < 0 or init_end < 0:
        sys.exit(f"FAIL: ecm_init() body not found in {init_path}")
    init_fn = init[init_start:init_end]
    db_init_pos = init_fn.find("ret = ecm_db_init(ecm_dentry);")
    ipv4_init_pos = init_fn.find("ecm_front_end_ipv4_init(ecm_dentry);")
    ct_init_pos = init_fn.find("ecm_conntrack_notifier_init(ecm_dentry);")
    if min(db_init_pos, ipv4_init_pos, ct_init_pos) < 0 or not (db_init_pos < ipv4_init_pos < ct_init_pos):
        sys.exit(f"FAIL: ECM DB must initialize before packet frontends and conntrack notifier in {init_path}")

    stop_start = db.find("void ecm_db_fib_rule_notifier_stop(void)")
    stop_end = db.find("EXPORT_SYMBOL(ecm_db_fib_rule_notifier_stop);", stop_start)
    if stop_start < 0 or stop_end < 0:
        sys.exit(f"FAIL: FIB notifier stop hook missing in {db_path}")
    stop_fn = db[stop_start:stop_end]
    ready_off = stop_fn.find("WRITE_ONCE(ecm_db_fib_rule_ready, false)")
    unregister = stop_fn.find("unregister_fib_notifier(&init_net, &ecm_db_fib_rule_nb)")
    cancel = stop_fn.find("cancel_work_sync(&ecm_db_fib_rule_work)")
    if min(ready_off, unregister, cancel) < 0 or not (ready_off < unregister < cancel):
        sys.exit(f"FAIL: stop hook must disarm, unregister, then drain work in {db_path}")
    if "void ecm_db_fib_rule_notifier_stop(void);" not in header:
        sys.exit(f"FAIL: stop-hook prototype missing in {header_path}")
    for cleanup in (
        "clear_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_clear_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(0)",
    ):
        if cleanup not in stop_fn:
            sys.exit(f"FAIL: notifier stop does not clear/release a pending gate in {db_path}: {cleanup}")

    db_exit_start = db.find("void ecm_db_exit(void)")
    db_exit_end = db.find("EXPORT_SYMBOL(ecm_db_exit);", db_exit_start)
    if db_exit_start < 0 or db_exit_end < 0:
        sys.exit(f"FAIL: ecm_db_exit() missing in {db_path}")
    db_exit = db[db_exit_start:db_exit_end]
    route_v4 = db_exit.find("if (ecm_db_ipv4_route_registered) {")
    route_v6 = db_exit.find("if (ecm_db_ipv6_route_registered) {")
    if route_v4 < 0 or route_v6 < 0:
        sys.exit(f"FAIL: DB exit does not gate route unregister by actual registration state in {db_path}")
    if "if (ecm_db_ipv4_route_enable) {" in db_exit or "if (ecm_db_ipv6_route_enable) {" in db_exit:
        sys.exit(f"FAIL: DB exit still unregisters route notifiers based only on enable flags in {db_path}")
    v4_unreg = db_exit.find("ip_rt_unregister_notifier(&ecm_db_iproute_table_update_nb)", route_v4)
    v4_clear = db_exit.find("ecm_db_ipv4_route_registered = false;", v4_unreg)
    v6_unreg = db_exit.find("rt6_unregister_notifier(&ecm_db_ip6route_table_update_nb)", route_v6)
    v6_clear = db_exit.find("ecm_db_ipv6_route_registered = false;", v6_unreg)
    if min(v4_unreg, v4_clear, v6_unreg, v6_clear) < 0 or not (route_v4 < v4_unreg < v4_clear and route_v6 < v6_unreg < v6_clear):
        sys.exit(f"FAIL: DB exit does not unregister and clear each successful route notifier in {db_path}")
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

    # Keep GNU patch fuzz from silently moving the worker drain elsewhere.
    exit_lines = exit_fn.splitlines()
    stop_lines = [
        index for index, line in enumerate(exit_lines)
        if line.strip() == "ecm_db_fib_rule_notifier_stop();"
    ]
    if len(stop_lines) != 1:
        sys.exit(f"FAIL: expected exactly one FIB worker drain call in {init_path}, found {len(stop_lines)}")
    stop_line = stop_lines[0]
    expected_next = r'DEBUG_INFO("stop conntrack notifier\n");'
    if stop_line + 1 >= len(exit_lines) or exit_lines[stop_line + 1].strip() != expected_next:
        context = "\n".join(exit_lines[max(0, stop_line - 2):min(len(exit_lines), stop_line + 4)])
        sys.exit(
            f"FAIL: FIB worker drain must immediately precede conntrack notifier shutdown in {init_path}:\n{context}"
        )

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

# The FIB notifier callback runs in atomic context. It closes the affected
# frontend gate and records the family, then queues process-context work.
# Sleeping and ECM DB defunct operations remain in the worker.
python3 - "$ECM_DB" "$SERIES_ECM_DB" <<'PY'
from pathlib import Path
import re
import sys

def check_atomic_callback(path):
    source = Path(path).read_text()
    start = source.find("static int ecm_db_fib_rule_event(")
    brace = source.find("{", start)
    end = source.find("\nstatic struct notifier_block ecm_db_fib_rule_nb", brace)
    if start < 0 or brace < 0 or end < 0:
        sys.exit(f"FAIL: FIB notifier callback is missing in {path}")
    body = source[brace + 1:end]

    required = [
        "event != FIB_EVENT_RULE_ADD",
        "event != FIB_EVENT_RULE_DEL",
        "switch (info->family)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv4_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV4, &ecm_db_fib_rule_pending)",
        "test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6, &ecm_db_fib_rule_gated)",
        "ecm_front_end_ipv6_stop_temp(1)",
        "set_bit(ECM_DB_FIB_RULE_PENDING_IPV6, &ecm_db_fib_rule_pending)",
        "READ_ONCE(ecm_db_fib_rule_ready)",
        "schedule_work(&ecm_db_fib_rule_work)",
        "return NOTIFY_DONE;",
    ]
    missing = [token for token in required if token not in body]
    if missing:
        sys.exit(f"FAIL: atomic FIB callback is missing required behavior in {path}: {missing}")

    calls = re.findall(r"\b([A-Za-z_]\w*)\s*\(", body)
    actual = [name for name in calls if name not in {"if", "switch"}]
    expected = [
        "test_and_set_bit", "ecm_front_end_ipv4_stop_temp", "set_bit",
        "test_and_set_bit", "ecm_front_end_ipv6_stop_temp", "set_bit",
        "READ_ONCE", "schedule_work",
    ]
    if actual != expected:
        sys.exit(
            f"FAIL: atomic FIB callback contains unexpected calls in {path}: {actual}; "
            "only atomic gate/set operations and deferred queueing are allowed"
        )
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV4") > body.find("ecm_front_end_ipv4_stop_temp(1)") or body.find("ecm_front_end_ipv4_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4"):
        sys.exit(f"FAIL: IPv4 gate must close before its pending bit is queued in {path}")
    if body.find("test_and_set_bit(ECM_DB_FIB_RULE_GATED_IPV6") > body.find("ecm_front_end_ipv6_stop_temp(1)") or body.find("ecm_front_end_ipv6_stop_temp(1)") > body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6"):
        sys.exit(f"FAIL: IPv6 gate must close before its pending bit is queued in {path}")
    if body.find("READ_ONCE(ecm_db_fib_rule_ready)") > body.find("schedule_work("):
        sys.exit(f"FAIL: FIB work is queued before checking initial-replay readiness in {path}")

    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV4") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv4 pending bit is set after queuing work in {path}")
    if body.find("set_bit(ECM_DB_FIB_RULE_PENDING_IPV6") > body.find("schedule_work("):
        sys.exit(f"FAIL: IPv6 pending bit is set after queuing work in {path}")

for source_path in sys.argv[1:]:
    check_atomic_callback(source_path)

print("PASS: FIB callback closes the frontend gate atomically, records pending family, then queues deferred work")
PY

echo "PASS: patch applies cleanly to the hash-verified pinned ECM source"
