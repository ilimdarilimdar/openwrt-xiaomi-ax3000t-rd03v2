# Porting the ECM policy-rule notifier from v1 to v2

## Finding

The Dual-WAN/ECM problem is not hypothetical. ADCDS merged [PR #40](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/pull/40)
for v1.x and included its ECM patch 0030 in v1.14. The v1 patch listens for
FIB policy-rule additions/deletions and defuncts ECM accelerated connections
of the affected address family.

The notifier callback does not flush the database directly: it runs in atomic
context, sets a per-family pending bit and schedules work. The worker stops the
relevant ECM front end, calls the existing per-IP-family defunct routine, then
restarts the front end. Module teardown unregisters the notifier and cancels
the work before final cleanup.

## Proven on v1.x, not yet proven on v2

PR #40 and its linked test report describe:
- A reproducible routed-IPv6 upload stall with stock ECM when mwan3-like policy
  rules were restored after routes.
- Recovery after the patched ECM saw rule-add/delete events.
- 800 rule changes in 4.4 seconds without kernel warnings.
- A reporter's approximately 16-hour run and three deliberate `mwan3 restart`
  operations with routed IPv6 flows recovering.

The same PR explicitly distinguishes this from NAT66: the investigated NAT66
flows were not ECM-offloaded and were reset by ordinary routing/masquerade
changes. It also states that IPv4 NAT sessions may be ended on WAN migration
by conntrack/mwan3 regardless of NSS. Therefore the patch is not a general
"preserve every session" solution.

## Exact v2 source pins

From this repository's v2.1.3 build inputs:
- OpenWrt/NSS base commit: `c36db6321c11595dc45a160cdab36b5c2d787744`.
- NSS feed commit: `57c0fa18f847f6cb23992ff3493c6a9131246f4c`.
- qca-nss-ecm source commit: `7894b769eeb64f1c44fde547a107a8b866997590`.
- qca-nss-ecm source version: QSDK 14.0, 2026-09-06.
- Kernel line: Linux 6.18.

The v2 project's own VALIDATION.md says the current ECM has no FIB-rule
notifier and lists issue #36 as not fully settled on the v2 test bench. That
is the reason for a separate v2 port rather than blindly applying the v1 patch.

## Reproducible source and patch preflight

The v2 ECM archive URL and digest are pinned by the qca-nss-ecm package
Makefile. Use these commands in the actual OpenWrt build workspace (or a
separate Linux host) to test the v1 reference patch against the exact v2 source
without changing the active feed overlay:

```sh
set -eu
WORK=/tmp/rd03v2-ecm-v2-preflight
mkdir -p "$WORK/source" "$WORK/reference"

ARCHIVE=qca-nss-ecm-14.0.2026.09.06.7894b769eeb64f1c44fde547a107a8b866997590.tar.zst
URL=https://github.com/kuncy7/nss-packages/releases/download/nss-source-tarballs/$ARCHIVE
SHA256=a4d5f4c4a6c4bfac3ded4af993c88249f7afc4444ed78368f367eda4ef231886

curl -fL "$URL" -o "$WORK/reference/$ARCHIVE"
printf '%s  %s\n' "$SHA256" "$WORK/reference/$ARCHIVE" | sha256sum -c -

PATCH_URL=https://raw.githubusercontent.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/d7b85aa5395aeefe29b7d02602c1a7e74e617c0e/nss/feed-patches/qca-nss-ecm/0030-ecm-db-defunct-on-policy-rule-changes.patch
curl -fL "$PATCH_URL" -o "$WORK/reference/0030-v1-reference.patch"

tar --zstd -xf "$WORK/reference/$ARCHIVE" -C "$WORK/source"
ECM_DB=$(find "$WORK/source" -type f -path '*/ecm_db/ecm_db.c' -print -quit)
test -n "$ECM_DB"
ECM_ROOT=${ECM_DB%/ecm_db/ecm_db.c}

(
  cd "$ECM_ROOT"
  patch -p1 --dry-run < "$WORK/reference/0030-v1-reference.patch"
)
```

Interpretation:

- A successful dry-run means the v1 patch context still matches the v2 source;
  it does **not** prove that the resulting module compiles or works.
- A failed dry-run is a stop condition. Inspect the actual v2 function bodies
  and port the notifier against their current signatures and teardown order.
  Do not hand-edit hunk offsets until the code context has been compared.
- The reference patch must not be copied into
  `feed-overlay/nss/qca-nss-ecm/patches/` yet. The active overlay currently
  contains only the existing RD03v2 patch 9001; a candidate 9002 belongs there
  only after review and successful compilation.
- After an approved patch is staged, compile the feed package in the prepared
  OpenWrt tree with:

```sh
make package/feeds/nss/qca-nss-ecm/compile V=s
```

Then inspect the produced `ecm.ko` for the runtime registration message
`ECM: policy routing rule changes defunct accelerated connections`, run
`tools/verify-v2.sh`, and test the module on a controlled bench before
building a sysupgrade image.

## v2 source review and candidate patch status (2026-11-15)

**RTNL publication-order and pending-bit race:** Linux 6.18 calls the rule-add notifier before the new rule is linked into the rules list, and the delete notifier after `list_del_rcu()` but before RTNL is released. The worker must therefore wait until the originating rule transaction commits before invalidating accelerated connections. The candidate takes RTNL, snapshots and clears the IPv4/IPv6 pending bits while still holding RTNL, then releases RTNL before walking the ECM database. This ordering closes a second race: if the worker cleared pending bits after releasing RTNL, a newer rule event could set a bit in between and have that event consumed by the older worker pass. An event arriving after the snapshot instead sets a fresh bit and schedules another pass. For `init_net`, `rtnl_net_lock()` acquires the global RTNL lock before the per-net lock, so the worker's RTNL acquisition acts as a publication barrier. RTNL is not held during ECM database traversal. The preflight script checks the relative order of lock, pending-bit snapshots, unlock and both family-specific defunct paths.
The Linux 6.18 event path was also checked in the exact tagged kernel sources:

- `net/core/fib_rules.c` builds `fib_rule_notifier_info` with
  `info.family = ops->family` and calls `call_fib_notifiers()`
  ([notifier wrapper](https://github.com/torvalds/linux/blob/v6.18/net/core/fib_rules.c#L368-L399)).
- The rule-add path calls `call_fib_rule_notifiers(..., FIB_EVENT_RULE_ADD, ...)`
  after the rule is configured
  ([add path](https://github.com/torvalds/linux/blob/v6.18/net/core/fib_rules.c#L920-L927)).
- The delete path calls `FIB_EVENT_RULE_DEL`
  ([delete path](https://github.com/torvalds/linux/blob/v6.18/net/core/fib_rules.c#L1091-L1099)).
- `net/core/fib_notifier.c` dispatches the chain with
  `atomic_notifier_call_chain()`
  ([dispatch](https://github.com/torvalds/linux/blob/v6.18/net/core/fib_notifier.c#L29-L39)).
  This confirms that the callback must remain short and defer database traversal to workqueue context.

The exact pinned QSDK 14.0 source was inspected at
`7894b769eeb64f1c44fde547a107a8b866997590`. The v2 code differs from the
v1 reference in a critical API detail:

- v2 exports `ecm_front_end_ipv4_stop_temp(int)` and
  `ecm_front_end_ipv6_stop_temp(int)`, backed by atomic nesting counters.
  A non-zero argument increments the temporary stop counter; zero decrements
  it if positive. It prevents new processing only at the call sites that
  check the counter. It is **not** a quiescence barrier and is not the old v1
  `ecm_front_end_ipv*_stop()` API. The candidate uses the v2 `stop_temp`
  helpers only.
- `ecm_db_connection_defunct_ip_version(4/6)` already exists in v2. It walks
  the connection database with references and short internal spin-lock
  sections, so it must run from process context, not from the atomic FIB
  callback.
- `ecm_db_init()` initializes the connection database, listener and timer
  before registering the existing IPv4/IPv6 route notifiers. The new FIB
  notifier is registered after those route notifiers. A registration failure
  is deliberately non-fatal and emits a warning; the return value is not
  allowed to overwrite the existing `ret` from route-notifier initialization.
- `ecm_db_exit()` sets its termination flag and unregisters route notifiers
  before freeing the database. The candidate unregisters the FIB notifier and
  calls `cancel_work_sync()` before setting the termination flag, so no
  callback can queue work against a database being torn down.
- Linux 6.18's `fib_notifier.h` exposes `struct fib_notifier_info.family`,
  `FIB_EVENT_RULE_ADD/DEL` and `register_fib_notifier()`. The callback only
  sets a per-family pending bit and schedules work; it does not walk the ECM
  database or take its locks.

An experimental candidate now exists at
`feed-overlay/nss/qca-nss-ecm/patches/9002-rd03v2-defunct-ecm-flows-on-fib-policy-rule-changes.patch`.
It is separate from the pinned upstream feed, after existing patch 9001. It
has **not yet passed the pinned-archive apply test, has not been compiled, and
has not been tested on hardware**. Do not call this feature implemented or
NSS-safe yet.

The preparation workflow now runs
`tools/test-ecm-fib-rule-patch.sh` after PREPARE_ONLY. The script reads the
exact QSDK version, source commit, archive URL and SHA-256 from the prepared
feed Makefile, downloads the archive, verifies its hash, applies patch 9002
with `git apply --check`, then checks for the expected notifier events and v2
temporary stop helpers. `verify-v2.sh` also checks the runtime registration
string inside `ecm.ko` in the final sysupgrade root filesystem. These are
intended gates; their CI results remain pending until a successful run reports
them.

## Porting checklist

- Extract and hash-verify the exact source archive from the pinned qca-nss-ecm
  package Makefile.
- Check current v2 definitions/call sites for:
  - `ecm_db_connection_defunct_ip_version()`;
  - `ecm_front_end_ipv4_stop_temp()` and `ecm_front_end_ipv6_stop_temp()` (the current v2 API);
  - `register_fib_notifier()` / `unregister_fib_notifier()`;
  - the event structure and `FIB_EVENT_RULE_ADD/DEL` family field;
  - the module init/exit error and teardown paths.
- Port notifier registration, pending-family bit handling, worker and teardown
  to the current file layout and Linux 6.18 API.
- Use a new patch number after the current feed's 0059 series; do not collide
  with upstream patches.
- Add build verification that the expected notifier string is present in
  `ecm.ko`, then runtime verification that registration succeeded.
- Compare control (stock ECM) and patched ECM under both rule restore orders.
  Include IPv4, routed IPv6, NAT66, PPPoE, DHCP/static WAN and actual cable pulls.
- Stress repeated rule changes and record kernel warnings, workqueue state,
  ECM rule counters, CPU, throughput and memory.

## Safety gate

The FIB notifier invalidates accelerated flows of an address family whenever
a policy rule changes. This is deliberately broad and may cause a short
slow-path/re-acceleration interval. It must be measured on the current v2
source and hardware before inclusion in a flashable image.

No v2 ECM patch is implemented by this document. It records the next
engineering step and the evidence required to accept it.


## Linux 6.18: initial FIB dump and replay

The notifier registration path has an important side effect that must be included
in the test plan. In Linux 6.18, `register_fib_notifier()` first runs the
registered FIB dump callbacks before it attaches the notifier to the live
atomic chain. Both family dump paths replay existing policy rules to the
provided notifier:

- IPv4: `fib4_dump()` calls `fib4_rules_dump()`.
- IPv6: `fib6_dump()` calls `fib6_rules_dump()`.
- `fib_rules_dump()` reports each existing rule as
  `FIB_EVENT_RULE_ADD`.

The candidate callback does not distinguish a replayed rule from a live rule
change. Consequently, registering or reloading ECM while policy rules already
exist schedules the worker to defunct accelerated connections for the
corresponding address family. The per-family pending bits coalesce events
while a worker pass is pending, but repeated events during/after a pass may
cause another pass.

This is a deliberate broad invalidation, not evidence of a WAN failure. On a
cold boot before useful traffic exists it should have little practical impact.
Reloading ECM on a live router may briefly move existing accelerated traffic
back to the host path and trigger re-acceleration. Record this as expected
behavior and measure its duration; do not describe it as session preservation.

The third argument passed to `register_fib_notifier()` is the optional reset
callback used if the FIB changes while the initial dump is in progress. Linux
retries an inconsistent dump (up to five attempts); with a NULL callback it
does not run a driver-specific reset function between attempts. The candidate
does not mirror routes/rules into a separate hardware FIB table, so do not
blindly transplant reset logic from hardware-switch FIB offload drivers.
Nevertheless, repeated rule churn during ECM module registration must be
tested. A registration warning means this feature is unavailable and is a
test failure for the Dual-WAN/ECM acceptance criteria.

Required bench cases added by this finding:

1. Load ECM with the normal local/main/default IPv4 and IPv6 rules already
   present; confirm registration succeeds and no kernel warning/oops occurs.
2. With active accelerated flows, reload ECM and record the expected
   family-wide defunct/re-acceleration interval.
3. Cause rapid mwan3 rule changes during registration; verify registration
   either completes with the notifier active or reports a clear failure, with
   no stale work, warning, hang or use-after-free.
4. Repeat module unload/load and inspect workqueue completion and notifier
   registration/unregistration logs.

Primary Linux 6.18 source references:

- [FIB notifier API](https://raw.githubusercontent.com/torvalds/linux/v6.18/include/net/fib_notifier.h)
- [FIB notifier registration and consistency retries](https://raw.githubusercontent.com/torvalds/linux/v6.18/net/core/fib_notifier.c)
- [IPv4 FIB dump and rule replay](https://raw.githubusercontent.com/torvalds/linux/v6.18/net/ipv4/fib_notifier.c)
- [IPv6 FIB dump and rule replay](https://raw.githubusercontent.com/torvalds/linux/v6.18/net/ipv6/fib6_notifier.c)
- [Generic FIB rule dump and FIB_EVENT_RULE_ADD](https://raw.githubusercontent.com/torvalds/linux/v6.18/net/core/fib_rules.c)

## Current preflight boundary

`tools/test-ecm-fib-rule-patch.sh` verifies the hash-pinned raw QSDK archive,
applies every preceding ECM feed patch in lexical/quilt order (including 9001),
then applies 9002 to the resulting tree. CI #72 and #74 passed that full-series
preflight for the previous revision of 9002. The current revision adds a guard
for the `ecm_db_init()` error path and extends the script to assert the guard
against both pristine and fully patched source. That revised guard has not yet
passed CI. Even a green full-series apply test does not prove that `ecm.ko`
compiles or runs: package compilation, the final `verify-v2.sh` marker check
and controlled hardware tests remain mandatory.
