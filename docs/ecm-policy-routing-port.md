# Porting the ECM policy-rule notifier from v1 to v2

## Finding

The Dual-WAN/ECM problem is not hypothetical. ADCDS merged [PR #40](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/pull/40)
for v1.x and included its ECM patch 0030 in v1.14. The v1 patch listens for
FIB policy-rule additions/deletions and defuncts ECM accelerated connections
of the affected address family.

The notifier callback does not flush the database directly: it runs in atomic
context, sets a per-family pending bit and schedules work. The worker stops the
relevant ECM front end, calls the existing per-IP-family defunct routine, then
restarts the front end. The v2 port additionally drains this work before the
front-end shutdown sequence: unregister the FIB notifier, wait for any active
atomic callbacks to quiesce, then call `cancel_work_sync()`. A fallback stop
remains in `ecm_db_exit()`.

## What v1.x demonstrated; what remains unproven on v2

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

The repository's inherited `VALIDATION.md` describes the upstream v2.1.3 baseline and predates this branch's experimental Dual-WAN changes. The active branch now carries a separate v2/QSDK 14.0 implementation in patch 9002. The inherited release validation is not evidence for or against the new branch's runtime behavior; only the specific CI and hardware results below apply.

## Historical v1-reference patch preflight (superseded for the current v2 port)

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

- This is a historical comparison procedure for the v1 reference patch, not the
  current v2 implementation workflow.
- Do **not** copy v1 patch 0030 into the v2 feed. The active v2 implementation
  is the separately reviewed patch 9002 in `feed-overlay/nss/qca-nss-ecm/patches/`.
- A v1 patch dry-run does not validate the v2 patch; use
  `tools/test-ecm-fib-rule-patch.sh`, which applies 9002 using OpenWrt's
  `patch -f -p1` semantics to the exact pinned QSDK source and then to the
  complete sorted feed patch queue.
- A source preflight is not a substitute for compilation, final image
  verification, runtime registration or hardware testing.

```sh
make package/feeds/nss/qca-nss-ecm/compile V=s
```

Then inspect the produced `ecm.ko` for the runtime registration message
`ECM: policy routing rule changes defunct accelerated connections`, run
`tools/verify-v2.sh`, and test the module on a controlled bench before
building a sysupgrade image.

## v2 source review and applied patch status (2026-11-16)

**Per-net RTNL publication-order and pending-bit race:** Linux 6.18 calls the rule-add notifier before the new rule is linked into the rules list, and the delete notifier after `list_del_rcu()` but before the per-net RTNL lock is released. The worker now uses the exact same `rtnl_net_lock(&init_net)` / `rtnl_net_unlock(&init_net)` pair as the `init_net` rule update. This is important when `CONFIG_DEBUG_NET_SMALL_RTNL` is enabled: a plain global `rtnl_lock()` alone would not serialize with the additional per-net mutex. The worker snapshots and clears IPv4/IPv6 pending bits while holding the matching per-net lock, then releases it before walking the ECM database. This also closes the pending-bit race: an event arriving after the snapshot sets a fresh bit and can schedule another pass. The preflight script checks lock, pending-bit snapshots, unlock and both family-specific defunct paths.
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
  `ecm_front_end_ipv6_stop_temp(int)`. In the **pinned QSDK 14.0 source**,
  these helpers originally assign a plain integer 0/1 flag; they are **not**
  atomic nesting counters. That is unsafe when the route-table notifier,
  interface notifier and the new FIB-rule worker overlap: one caller can
  clear the flag while another caller is still defuncting connections.
- Candidate patch 9002 now converts each flag to `atomic_t`. A non-zero
  argument uses `atomic_inc()`; zero uses `atomic_dec_if_positive()`, and
  all six IPv4/IPv6 packet-hook checks use `atomic_read()`. This makes the
  temporary stop a balanced nesting gate across concurrent users and guards
  against a negative count. The preflight checks both the raw pinned source
  and the result after the complete feed patch series.
- The helper still is **not a quiescence barrier**: it prevents new processing
  only at the call sites that check the flag and does not wait for already
  executing packet hooks to exit. It is not the old v1
  `ecm_front_end_ipv*_stop()` API. The overlap fix remains compile/runtime/
  hardware-unverified until CI and second-router tests pass.
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

The active implementation is:
`feed-overlay/nss/qca-nss-ecm/patches/9002-rd03v2-defunct-ecm-flows-on-fib-policy-rule-changes.patch`.
It is a separate RD03v2/QSDK 14.0 port, applied after pinned feed patch 9001.

Evidence:
- CI #123 and #124 passed the SHA-256-verified raw QSDK source apply and the
  complete sorted queue of 32 ECM feed patches using `patch -f -p1`.
- Lifecycle guards passed: FIB notifier init/unwind/normal-exit ordering,
  pending work drain before frontend teardown, atomic callback restrictions,
  RTNL/pending-bit and `synchronize_net()` requirements.
- CI #124 compiled `qca-nss-ecm`, packaged `kmod-qca-nss-ecm`, created both
  image types and found the notifier marker in image `ecm.ko`.
- CI #124's final `verify-v2` still failed on watchdog scenarios and two ECM
  source-fingerprint checks after `CONFIG_AUTOREMOVE=y`; those were verifier/
  harness issues, not an ECM C compilation failure.
- The watchdog/AUTOREMOVE fixes were committed later, but #127's full build
  was interrupted by runner shutdown (exit 143), #128/#129 were cancelled,
  and code/test HEAD `49d3579` has no separate Actions run/status.

The current preflight script is `tools/test-ecm-fib-rule-patch.sh`. It reads
the source version/commit/archive URL/SHA from the pinned feed Makefile,
hash-verifies the QSDK archive, applies 9002 with the same `patch -f -p1`
semantics as OpenWrt, and checks the full ordered feed series and lifecycle
invariants. The `verify-v2.sh` marker check proves that the registration
string is present in the built image module; it does not prove runtime
registration on a router.

Patch 9002 is therefore **source-preflight PASS and compile/image PASS on
CI #124's older code/test revision; latest verifier fixes NOT CI-VALIDATED;
runtime/hardware NOT TESTED**. Do not call the feature production-ready or
NSS-safe yet.

## Remaining v2 validation checklist

The source port itself is present and has passed the source/build gates listed
above. The remaining tasks are validation, not porting the patch from scratch:

- finish a full CI run on current code/test HEAD and pass `verify-v2.sh`;
- review and, where possible, remove GNU patch fuzz reported for 9002 in #124;
- confirm the notifier actually registers on a booted RD03v2 and unregisters
  cleanly on module teardown;
- test initial FIB dump/replay, rule churn during registration, both families,
  pending-bit coalescing and worker drain under load;
- run lockdep/concurrency/teardown tests and save dmesg/workqueue/counter logs;
- compare rule-restore order, IPv4 routed/NAT, IPv6 routed/NAT66 where supported,
  PPPoE and both WAN types;
- measure slow-path/re-acceleration, CPU, throughput, RAM, latency and packet loss;
- run mwan3 tracker `disconnected`, netifd `ifdown`, cable pulls and recovery
  as separate scenarios, with conntrack marks recorded independently of ECM.

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

## Current preflight/build status — 2026-11-16

Pinned QSDK 14.0 source:
- source commit: `7894b769eeb64f1c44fde547a107a8b866997590`;
- archive: `qca-nss-ecm-14.0.2026.09.06.7894b769eeb64f1c44fde547a107a8b866997590.tar.zst`;
- SHA-256: `a4d5f4c4a6c4bfac3ded4af993c88249f7afc4444ed78368f367eda4ef231886`.

- CI #123: raw apply and full sorted 32-patch ECM queue PASS; notifier init/unwind/normal-exit ordering, worker drain, and atomic callback guards PASS.
- CI #124: the same preflight/source guards PASS; `qca-nss-ecm` compiled, `kmod-qca-nss-ecm` entered rootfs, image marker found, sysupgrade and initramfs-factory images created.
- CI #124 final `verify-v2`: FAIL on watchdog 20/46 and source-fingerprint checks for 9001/9002 after AUTOREMOVE.
- CI #127: Static and PREPARE_ONLY PASS; full build interrupted by runner shutdown (exit 143). #128/#129 cancelled before jobs.
- Current code/test HEAD `49d3579`: no separate workflow run or commit status. Runtime/module/hardware verification remains NOT TESTED.

A successful source-preflight and the older CI #124 compile/image result do not validate the later verifier fixes or runtime notifier behavior. The exact current CI status and all remaining tasks are maintained in [OPEN_ITEMS_REGISTER_RU.md](OPEN_ITEMS_REGISTER_RU.md).

## Concurrent temporary-stop accounting — corrected source audit, 2026-11-15

An earlier draft incorrectly described the pinned QSDK `stop_temp()` helpers as plain integer assignments. The exact pinned source already declares IPv4 and IPv6 temporary-stop state as `atomic_t`, increments it with `atomic_inc()`, and performs a read-then-`atomic_dec()` release. The common packet hooks already use `atomic_read()` while holding the corresponding `ecm_ipv4_lock` or `ecm_ipv6_lock`.

The actual race is narrower:
- stop-counter updates in the original helper do not take the family lock used by packet hooks;
- the original `atomic_read() > 0` followed by `atomic_dec()` is a check-then-update sequence and is not one indivisible decrement;
- therefore the packet-hook check and the stop-state update are not serialized by a common lock.

The corrected patch 9002 moves each existing atomic counter and its public helper implementation from the separate IPv4/IPv6 front-end source into the corresponding common front-end source, beside the family spinlock. The helper now takes that lock, uses `atomic_inc()` for stop and `atomic_dec_if_positive()` for release, then unlocks. The six existing packet-hook `atomic_read()` checks are already protected by the same locks, so the corrected patch deliberately does not rewrite those expressions.

The direct helper callsites found in the pinned source are in `ecm_db.c` route-notifier/proc-control paths and `ecm_interface.c` node-connection defunct handling. The inspected caller bodies do not already hold the same family lock, so the added helper lock does not show an obvious recursive acquisition in those call paths. This is a targeted caller review, not a substitute for lockdep and concurrency stress testing.

### CI finding and correction

Run [#93](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43723568587), source `f9b71d7`, passed static checks and OpenWrt PREPARE_ONLY source/config preparation, and verified the pinned archive checksum. Its ECM preflight then failed because patch hunks expected the wrong original declarations/reads; the full build was skipped. The error identified the six IPv4/IPv6 frontend/header/common-source hunks, not an ECM compiler failure.

Corrected patch/preflight commit: `d08e5d8b44276f306244b02b56ed9f090809e5e1`. It now targets the actual atomic QSDK baseline described above.

Run [#94](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43725992804), source `d08e5d8`, passed Static and PREPARE_ONLY source/config preparation, but ECM preflight failed with `corrupt patch` at line 369. The archive checksum was valid; the failure was unified-diff metadata (two lock hunks and the IPv6 include hunk had incorrect line counts), not a source/compiler failure. Full build was skipped.

Commit `1121ec832d1903ee530fd824681a32f3b7b39a6e` fixes the patch headers and diffstat. A structural check parsed all 19 hunks and confirmed that each declared old/new line count matches its actual body. Run [#95](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43726388183), source `1121ec8`, was queued at the last live check (2026-11-15 14:48 UTC). This parser check does not replace the CI apply check; wait for #95's ECM preflight result before calling the patch apply-validated.

The FIB worker's `synchronize_net()` barrier remains separate from the temporary-stop counter fix. It closes the affected frontend gates, waits for already-running Netfilter hook readers after RTNL is released, and only then walks the ECM database. This barrier does not preserve conntrack/NAT sessions across WAN address changes, and it does not serialize unrelated route/interface notifier DB walks.

Kernel source references for the exact 6.18 API:
- `nf_hook()` RCU critical section:
  https://github.com/torvalds/linux/blob/v6.18/include/linux/netfilter.h#L227-L277
- `synchronize_net()` implementation:
  https://github.com/torvalds/linux/blob/v6.18/net/core/dev.c#L12108-L12121
- `synchronize_net()` declaration:
  https://github.com/torvalds/linux/blob/v6.18/include/linux/netdevice.h#L90
