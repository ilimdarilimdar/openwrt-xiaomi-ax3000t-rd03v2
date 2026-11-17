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
  both temporary-stop states are already `atomic_t`; packet hooks read them
  with `atomic_read()`. The defect was narrower: the original helper used a
  check-then-`atomic_dec()` release without taking the family lock, while
  packet-hook reads were protected by that lock. The update and read paths
  therefore did not share one synchronization domain, and overlapping stop
  callers could race while releasing the gate.
- Patch 9002 moves each existing atomic counter and helper into the matching
  common frontend source beside its family lock. The helper takes that lock,
  uses `atomic_inc()` for stop and `atomic_dec_if_positive()` for release,
  then unlocks. The six packet-hook `atomic_read()` checks remain in place
  because they were already protected by the same locks. The preflight checks
  the raw pinned source and the result after the complete feed patch series.
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
  before registering the existing IPv4/IPv6 route notifiers. Their return
  values are kept in a separate `route_ret`; the first error is retained in
  `ret`, and success flags are set independently for each family. A later
  IPv6 success cannot mask an earlier IPv4 failure, or vice versa.
- If either route notifier fails, `ecm_db_init()` calls `ecm_db_exit()` and
  returns the original error before attempting FIB notifier registration.
  `ecm_db_exit()` unregisters only route notifiers whose registration flags
  are set, so a partial registration is rolled back without unregistering a
  family that never registered.
- The FIB notifier is registered only after both enabled route notifiers
  succeed. If its registration fails, `ecm_db_init()` calls `ecm_db_exit()`
  and returns `fib_ret`. The pinned QSDK `ecm_init()` calls
  `ecm_db_init()` before IPv4/IPv6 packet frontends and conntrack notifier
  initialization, so the ECM module aborts before installing those hooks.
- `ecm_db_exit()` first unregisters/drains the FIB notifier worker, then
  marks the DB terminating, unregisters only successfully registered route
  notifiers, and frees the database.
- Linux 6.18's `fib_notifier.h` exposes `struct fib_notifier_info.family`,
  `FIB_EVENT_RULE_ADD/DEL` and `register_fib_notifier()`. The callback closes the affected family frontend gate with a non-sleeping
  helper, records the pending bit and queues work only after the initial dump
  readiness barrier; it does not walk the ECM database.

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
  was interrupted by runner shutdown (exit 143), #128/#129 were cancelled.
  Later notifier rollback source/test commits are newer than #129 and have no
  CI run. The read-only Actions API does not expose why no run was created; the
  last UI observation (2026-11-16) reported a usage-related pause, but current
  UI/settings state has not been rechecked.



### Current source revision and validation state — 2026-11-17

Source implementation `16193bfb29eecca103a370270458a779403ac619`; patch-envelope repair `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`; functional test-harness commit `bfaae52f6714ec93d25dc3537bf392fa3f374f53`; latest comment-only test-script commit `ca75381492a743afba382a1d205c922913ef66e6`. Patch blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`; test-harness blob `fd27275abff514c8578c30963eb380c551023fc0`; code/test HEAD `ca75381492a743afba382a1d205c922913ef66e6`. Subsequent branch revisions are documentation-only.

The candidate closes the affected IPv4/IPv6 frontend gate directly from the
atomic notifier callback on the first event, using a gated-state bit to avoid
double-incrementing the temporary-stop counter. The callback records the family
pending bit and queues work only after register_fib_notifier() initial
dump/replay has completed. The worker loops until both pending-family bits are
empty and opens gates only under per-net RTNL after the final empty check.
Teardown disarms queueing, unregisters the notifier, drains work and cleans
residual gated/pending state.

The test harness has source guards for callback gate-before-pending order,
initial-replay readiness, drain-loop and RTNL-serialized gate release. These
guards are committed but have not been executed against the exact QSDK archive.
A self-audit found and repaired malformed patch metadata plus a stray NaN/0
line before DECLARE_WORK in f9f33b314ef11ad42037ad81de18e05f6e0e11f3. The strict envelope/hunk check now
passes (9 file sections, 22 hunks); this is not a substitute for applying the
patch to the exact QSDK archive.

**Validation status:** exact pinned QSDK apply, complete 32-patch feed series,
current C compilation, full verify-v2, fault injection, lockdep/KASAN and
hardware runtime remain **NOT TESTED**. The code changes RTNL → ECM frontend
spinlock ordering and requires lockdep confirmation. CI #123/#124 results
apply to an earlier implementation, not to this candidate. No CI run/status
exists for the current patch/test candidate.

The marker check in ecm.ko proves only that a registration string was
compiled into the module; it does not prove runtime notifier registration.


## Worker requeue window — gate-first candidate implementation

The former one-pass worker could open its gate after one pending-bit snapshot
while another FIB update had already requeued the same work item. The current
candidate addresses both the inter-pass gap and the callback-to-worker gap:

1. The first IPv4/IPv6 FIB callback atomically sets a gated-state bit and closes
   the corresponding frontend gate before publishing the pending bit.
   Additional events coalesce and do not increment the temporary stop counter
   a second time.
2. Initial register_fib_notifier() dump/replay can call the notifier under RCU
   without RTNL. The callback records/gates those events but does not queue
   work while ecm_db_fib_rule_ready is false. After registration succeeds,
   the caller arms readiness with WRITE_ONCE and schedules one worker.
3. The worker takes the same per-net RTNL used by live FIB rule ADD/DEL
   callbacks, snapshots/clears pending-family bits, releases RTNL for
   synchronize_net() and the ECM DB defunct walk, then loops. Gates stay
   closed across passes. The final empty check and gate release occur under
   RTNL, preventing a live rule update from slipping between them.
4. Teardown sets readiness false, unregisters the notifier, cancels/drains the
   worker, and under RTNL clears leftover pending bits and releases any
   callback-owned gate left by a cancelled worker.

The RTNL serialization is supported by Linux 6.18.55
[call_fib_rule_notifiers()](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_rules.c#L388-L399),
which asserts per-net RTNL for live changes, while
[fib_rules_dump()](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_rules.c#L401-L424)
runs under RCU for initial replay. This source-level rationale does not prove
the lock order against every pinned QSDK callsite; the new RTNL →
frontend-spinlock order must be exercised with lockdep.

**Status:** implementation and static guards are committed. Exact archive
apply, C compilation, fault/stress injection, lockdep/KASAN and runtime remain
**NOT TESTED**. ECM-06 stays open until those checks pass.


## Remaining v2 validation checklist

The source port itself is present and has passed the source/build gates listed
above. The remaining tasks are validation, not porting the patch from scratch:

- finish a full CI run on the gate-first source/test candidate and pass `verify-v2.sh`;
- review and, where possible, remove GNU patch fuzz reported for 9002 in #124;
- confirm the notifier actually registers on a booted RD03v2 and unregisters
  cleanly on module teardown;
- test initial FIB dump/replay/retry, event injection during active worker defunct passes, callback-owned gate retention, final empty-pending release under RTNL and both families,
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

The v2 ECM patch is implemented in the active feed overlay. This document
records its rationale, source review and acceptance criteria; it does not
constitute runtime validation or a release approval.


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

The exact Linux v6.18.55 registration/error path adds an important
lifecycle distinction:

- `fib_net_dump()` runs the per-family dump callbacks under RCU before the
  notifier is attached to the live atomic chain. Existing rules are replayed
  to the supplied callback as `FIB_EVENT_RULE_ADD`.
- A dump callback error is returned immediately by
  `register_fib_notifier()`; the live notifier has not yet been registered.
  The ECM callback may nevertheless have recorded gated/pending state during
  the partial replay, so the caller must still unwind that state.
- After a successful dump, Linux attaches the atomic notifier and compares
  the FIB sequence with the pre-dump snapshot. If it changed, Linux removes
  the just-attached notifier and retries. The maximum is five attempts; after
  repeated inconsistency registration returns `-EBUSY`.
- Removing an atomic notifier calls `synchronize_rcu()`. Thus a successful
  `unregister_fib_notifier()` return is the callback-quiescence boundary;
  `cancel_work_sync()` then drains deferred ECM work. The patch's
  `registered` flag, readiness barrier, and unregister-before-cancel order
  match this sequence at source level.

This is a static review of the pinned kernel source, not evidence that the
current ECM patch compiles or that fault injection/runtime teardown is safe.
The current preflight harness checks ECM source ordering and cleanup markers;
it does not execute the kernel's registration retry/error state machine.
That behavior must still be exercised by fault injection or a focused test
once the full CI and build environment are available.

Pinned Linux v6.18.55 source references:

- [FIB notifier registration/dump/retry](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_notifier.c#L58-L125)
- [Atomic notifier unregister and synchronize_rcu](https://github.com/gregkh/linux/blob/v6.18.55/kernel/notifier.c#L177-L198)
- [FIB rule dump and live ADD/DEL notification under per-net RTNL](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_rules.c#L390-L425)

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

- [FIB notifier API](https://github.com/gregkh/linux/blob/v6.18.55/include/net/fib_notifier.h)
- [FIB notifier registration and consistency retries](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_notifier.c)
- [IPv4 FIB dump and rule replay](https://github.com/gregkh/linux/blob/v6.18.55/net/ipv4/fib_notifier.c)
- [IPv6 FIB dump and rule replay](https://github.com/gregkh/linux/blob/v6.18.55/net/ipv6/fib6_notifier.c)
- [Generic FIB rule dump and FIB_EVENT_RULE_ADD](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_rules.c)

## Historical preflight/build evidence — CI #123/#124 and #127 (2026-11-16)

Pinned QSDK 14.0 source:
- source commit: `7894b769eeb64f1c44fde547a107a8b866997590`;
- archive: `qca-nss-ecm-14.0.2026.09.06.7894b769eeb64f1c44fde547a107a8b866997590.tar.zst`;
- SHA-256: `a4d5f4c4a6c4bfac3ded4af993c88249f7afc4444ed78368f367eda4ef231886`.

- CI #123: raw apply and full sorted 32-patch ECM queue PASS; notifier init/unwind/normal-exit ordering, worker drain, and atomic callback guards PASS.
- CI #124: the same preflight/source guards PASS; `qca-nss-ecm` compiled, `kmod-qca-nss-ecm` entered rootfs, image marker found, sysupgrade and initramfs-factory images created.
- CI #124 final `verify-v2`: FAIL on watchdog 20/46 and source-fingerprint checks for 9001/9002 after AUTOREMOVE.
- CI #127: Static and PREPARE_ONLY PASS; full build interrupted by runner shutdown (exit 143). #128/#129 cancelled before jobs.
- The active source candidate is patch blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659` (implementation `16193bfb29eecca103a370270458a779403ac619`, envelope repair `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`); current preflight harness blob is `fd27275abff514c8578c30963eb380c551023fc0` (functional commit `bfaae52f6714ec93d25dc3537bf392fa3f374f53`, latest comment-only commit `ca75381492a743afba382a1d205c922913ef66e6`). The expanded cleanup guard verifies source-level unconditional work drain and per-family gate cleanup after failed initial registration; it does not execute real kernel failure/retry paths. No workflow run or commit status exists for code/test HEAD `ca75381492a743afba382a1d205c922913ef66e6` after #129. The current candidate has no completed CI. Runtime/module/hardware verification remains NOT TESTED.

The historical source-preflight and CI #124 compile/image result do not validate the current transactional rollback patch or runtime notifier behavior. The exact current CI status and all remaining tasks are maintained in [OPEN_ITEMS_REGISTER_RU.md](OPEN_ITEMS_REGISTER_RU.md).

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
