# Dual-WAN baseline for Xiaomi AX3000T RD03v2

This branch adds upstream `mwan3` and `luci-app-mwan3` to the RD03v2 image.
The package selections use the feed revisions pinned in `feeds.lock`:
`mwan3` 2.12.5 from the packages feed and `luci-app-mwan3` from the LuCI
feed. Their declared package dependencies are resolved by OpenWrt Kconfig.

This is an **experimental source/configuration baseline**, not a
production-validated Dual-WAN/NSS firmware. The package selections are
committed; the current transactional ECM notifier changes have not yet passed
a fresh full build or hardware validation.

The authoritative task list and closure criteria are in
[OPEN_ITEMS_REGISTER_RU.md](OPEN_ITEMS_REGISTER_RU.md).

## What this change does

- Adds upstream `mwan3` and `luci-app-mwan3` using the pinned feeds.
- Adds nft-backed compatibility packages required by mwan3 with firewall4:
  `iptables-nft`, `ip6tables-nft`, `xtables-nft`, `ipset` and the selected
  xtables extensions.
- Adds experimental ECM patch 9002 for FIB policy-rule ADD/DEL events. Its
  atomic notifier callback closes the affected family's frontend gate on the
  first event, records a pending bit and queues deferred work after initial
  FIB replay. The worker drains coalesced events in a loop, waits for network
  readers and invalidates accelerated connections for each pending family.
- Adds source preflight and lifecycle guards intended to reproduce the pinned
  OpenWrt patch application path (`patch -f -p1`) against the hash-verified
  QSDK source and after the complete sorted ECM feed patch queue.

## Current validation status — 2026-11-16

- Working branch: work/rd03v2-dualwan-mwan3-baseline.
- Source implementation commit: 16193bfb29eecca103a370270458a779403ac619; patch-envelope repair: f9f33b314ef11ad42037ad81de18e05f6e0e11f3; functional test-harness commit: 0ca5b790cded21107f4ca72b987d3129790a9b18; latest comment-only / CI-trigger commit: 5b3328e23d36b2b1089e4b2342e0a5255578e022 (no test or firmware behavior change). Current patch blob: 3dbe8c97bdab7ee7452fc49b4ae77580788ef659; current test-harness blob: dbb7859aed90d1b125de28801dd44d6826d3a2fe. Code/test HEAD: 5b3328e23d36b2b1089e4b2342e0a5255578e022; branch HEAD: ffb68d29abd777bed44cb113887649fe88557698; the two commits after code/test HEAD only update documentation.
- Candidate 9002 closes per-family gates directly in the atomic callback on the first ADD/DEL event, uses a readiness barrier for initial FIB replay, a drain-loop worker, RTNL-serialized final gate release and teardown cleanup.
- The callback closes the gate before publishing the pending bit. Repeated events coalesce and do not increment the temporary-stop counter repeatedly. During initial register_fib_notifier replay the callback does not queue work; after successful return the caller arms ready and schedules one worker.
- Live rule ADD/DEL callbacks run under per-net RTNL. Worker uses the same RTNL lock for pending snapshot and final empty-check/gate release; it does not hold RTNL across synchronize_net() or the ECM DB walk.
- This is **NOT CI-VALIDATED**. Exact pinned QSDK archive apply, complete sorted 32-patch feed queue, current C compilation, fault injection, lockdep/KASAN and runtime stress have not been executed. RTNL → ECM frontend spinlock ordering must be checked with lockdep.
- CI #123/#124 apply/source guards and #124 compile/image generation refer to an earlier patch version. #124 final verify-v2 failed (watchdog 20/46 and two AUTOREMOVE source-fingerprint false negatives).
- #127 passed Static/PREPARE_ONLY but full-build was interrupted by runner shutdown (exit 143); #128/#129 were cancelled before jobs. API latest remains #129; no Actions run/status for this new candidate.
- workflow_dispatch exists with full_build=false/true, but neither dispatch has run for code/test HEAD `5b3328e23d36b2b1089e4b2342e0a5255578e022`. The read-only API still shows #129 as latest and empty commit-status lists for the current code/test and branch HEADs; the last UI pause observation was on 2026-11-16 and is not asserted as the current UI state.
- PREPARE_ONLY artifact #124 selected RD03v2 qualcommax/ipq50xx, mwan3, LuCI mwan3, ECM/NSS and nft-compatible xtables packages. Three unrelated Kconfig diagnostics remained for Qt5 GUI, fwknopd/LuCI fwknopd and squeezelite-custom; those packages were unset. Selected NSS dependency cycle was absent after tree patch 0014.
- Userspace conntrack CLI is **not selected**. iptables-mod-conntrack-extra is not that CLI; selective WAN-mark-based conntrack cleanup is not implemented.
- CI uses a disposable signing key and example.invalid; it does not publish installable firmware. **Do not flash CI images.**
- Runtime firewall4/mwan3, Dual-WAN failover, conntrack marks, ECM/NSS datapath, throughput, RTT, jitter, packet loss and game traffic are **NOT TESTED**. Primary home router remains on stock MiWiFi; testing is reserved for a second RD03v2 after build and recovery gates pass.


## v1.x reference and the separate v2 port

The ADCDS v1.x line already addressed the ECM/mwan3 policy-routing problem in
[PR #40](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/pull/40).
The fix was included in v1.14 as ECM patch 0030. It registers a FIB notifier
for `FIB_EVENT_RULE_ADD` and `FIB_EVENT_RULE_DEL`, then defuncts accelerated
connections of the affected address family from a work item. Deferring the
flush is necessary because the notifier callback runs in atomic context.

The v1.x maintainer and reporter documented the following evidence:

- The wrong-WAN stall was reproduced with stock ECM on a bench topology using
  PPPoE, a second WAN, per-WAN fwmark rules and routed IPv6.
- With rules restored last, a routed IPv6 upload could remain at 0 Mbit/s for
  the rest of a 40-second run. With the notifier patch, it recovered as soon as
  the rules returned.
- 800 policy-rule changes in 4.4 seconds produced no kernel warnings in the
  maintainer's test.
- The reporter ran the patched module for about 16 hours and deliberately
  triggered three `mwan3 restart` operations; routed IPv6 flows recovered
  rather than remaining stalled.

This is evidence for that **v1.x ECM/kernel combination**, not proof for v2.
The v2 source and Linux 6.18 notifier API differ. The v1 patch must not be copied into v2 unchanged; patch 9002 is a separate adaptation checked against the exact pinned QSDK source and the complete pinned ECM feed patch series. Applying the patch is only a source-level gate; compilation and hardware behavior still have to be established.

The current v2 pins are materially different:

- OpenWrt/NSS tree: `c36db6321c11595dc45a160cdab36b5c2d787744`, Linux 6.18.
- NSS feed: `57c0fa18f847f6cb23992ff3493c6a9131246f4c`.
- `qca-nss-ecm` source: QSDK 14.0, source commit
  `7894b769eeb64f1c44fde547a107a8b866997590`, dated 2026-09-06.

See [v2 validation](../VALIDATION.md), [PR #40](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/pull/40)
and [the v1.14 release](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/releases/tag/v1.14).

## What the v1 fix does not promise

- IPv4 NAT sessions are not guaranteed to survive WAN migration. Conntrack/NAT
  state is tied to the path and mwan3 may flush affected connections. The
  expected success criterion is that new connections use the surviving WAN.
- NAT66 was observed in the v1 investigation to stay on the host/slow path,
  rather than ECM NSS acceleration. Its behaviour must be confirmed against
  the v2 image; do not assume the FIB notifier makes NAT66 sessions survive.
- The notifier invalidates accelerated flows for the affected IP family. That
  creates a brief slow-path/re-acceleration interval on policy-rule changes.
- mwan3 performs per-connection policy distribution/failover. It does not
  bond two WANs into one faster TCP stream.

## Failover events, conntrack marks and the ECM notifier

The exact pinned mwan3 2.12.5 scripts distinguish a health-check **`disconnected`**
event from a netifd **`ifdown`** event. This distinction is essential for the
RD03v2 ECM/FIB work:

- On `disconnected`, the hotplug script marks the interface offline and rebuilds
  the policy mangle chains. It does not delete that interface's `ip rule` entries
  or routing table. Therefore this event alone does not necessarily emit a FIB
  rule ADD/DEL notification for patch 9002 to observe.
- On `ifdown`, the script deletes the interface's policy rules, routes and
  per-interface mangle chain, then rebuilds the policies. Those rule deletions
  are the events that can reach the new ECM FIB notifier.
- The general mwan3 hook restores the saved connection mark with
  `CONNMARK --restore-mark` before policy evaluation, and saves a newly selected
  mark with `CONNMARK --save-mark`. Existing conntrack entries can therefore
  retain the old WAN mark instead of being re-evaluated against the updated
  policy. Defuncting an ECM/NSS accelerated connection does **not** erase or
  rewrite that conntrack mark.
- `mwan3_flush_conntrack()` performs a global conntrack-table flush by writing
  to `/proc/net/nf_conntrack`. It runs only when the interface's
  `list flush_conntrack` contains the current event. The pinned sample config
  does not enable this option by default. Do not enable global flushing blindly:
  it can interrupt unrelated flows, including traffic using the surviving WAN.

Primary source for these statements is the project's exact pinned
[`mwan3.sh`](https://github.com/openwrt/packages/blob/3a4f118a016af8a250fc77bb51b92aa2daf91f0a/net/mwan3/files/lib/mwan3/mwan3.sh),
[`15-mwan3` hotplug script](https://github.com/openwrt/packages/blob/3a4f118a016af8a250fc77bb51b92aa2daf91f0a/net/mwan3/files/etc/hotplug.d/iface/15-mwan3)
and [sample config](https://github.com/openwrt/packages/blob/3a4f118a016af8a250fc77bb51b92aa2daf91f0a/net/mwan3/files/etc/config/mwan3).

**Engineering consequence:** patch 9002 is an ECM acceleration invalidation
mechanism for FIB policy-rule changes. It is not a conntrack mark migration
mechanism and not, by itself, a complete response to every mwan3 tracker
`disconnected` event. The expected baseline is that *new* connections use the
surviving WAN. Existing sessions may stall or terminate and must not be described
as transparently migrated to another public source address.

Required bench cases, kept separate:

1. Force a mwan3 tracker `disconnected` state while the netifd interface remains
   up. Record `ip rule`, all route tables, the old connection's conntrack mark,
   per-WAN packet captures and ECM/NSS counters. Confirm whether any FIB event
   occurs; do not assume it does.
2. Cause a real netifd `ifdown`/cable pull. Confirm the WAN rules/routes are
   removed, patch 9002 receives the rule event, and the old conntrack mark is
   still inspected independently of ECM acceleration state.
3. On the isolated bench only, compare the effect of
   `list flush_conntrack 'ifdown'`. Measure collateral loss of unrelated
   connections; this option is global, not per-WAN selective cleanup.
4. Only after these observations, evaluate a selective conntrack cleanup keyed
   to mwan3's mark and mask. Treat it as a separate feature requiring its own
   tests; do not silently add it to the base firmware.
   Implementation guardrails for that future feature:

   - The image currently does not select the userspace `conntrack` command.
     `iptables-mod-conntrack-extra` is a separate xtables/kernel extension,
     not the CLI. The pinned packages feed provides `conntrack` through
     `conntrack-tools` 1.4.8; add that package explicitly before using
     `conntrack -D`.
   - The pinned `16-mwan3-user` hotplug script runs `/etc/mwan3.user` with
     `env -i`. The custom script must source its own OpenWrt helper libraries
     and call `config_load mwan3` itself; parent-shell UCI state is not passed
     into it.
   - Resolve the interface ID with mwan3's own helper and compute the mark
     through `mwan3_id2mask` using the configured `mmx_mask`. Validate that
     the ID is numeric and non-zero, and fail closed if configuration, mask,
     or `conntrack` is unavailable. Never fall back to a zero mark or a global
     flush.
   - Test IPv4 and IPv6 deletion separately on the secondary router, then
     confirm that unrelated WAN/LAN and router-originated conntrack entries
     remain untouched.


Useful evidence includes `ip -4 rule show`, `ip -4 route show table all`,
`conntrack -L -o extended`, `mwan3 status`, `logread`, packet captures on
both WAN devices, and ECM/NSS counters before and after each event.

## WAN and VPN configuration sequence

1. Bring up each WAN independently in `/etc/config/network`. Verify address,
   gateway, DNS, MTU and physical DSA device before configuring mwan3.
2. Use the actual netifd logical interface names in mwan3. Do not assume the
   second interface is named `wanb`.
3. Start with failover using different metrics. Confirm both new and existing
   traffic behaviour separately when either uplink is physically disconnected.
4. Add weighted balancing only after failover is understood. Test multiple
   independent flows and inspect per-WAN counters; one TCP flow is not an
   aggregation benchmark.
5. Test IPv4 and IPv6 separately. Configure IPv6 tracking only if both ISPs
   actually provide usable IPv6; no working IPv6 has been confirmed on the
   user's two links.
6. Test AmneziaWG policy separately. The AWG packages are built separately
   for the exact image/kernel and installed from the project's signed package
   repository; they are not installed in the base image. VPN traffic is CPU
   path on this platform, while ordinary non-VPN NAT can still use NSS.

## Firewall backend: mwan3 2.12.5 with firewall4

The pinned `packages` feed's mwan3 2.12.5 package depends on `iptables`,
`ipset`, `iptables-mod-conntrack-extra`, `iptables-mod-ipopt`, and
`ip6tables` when IPv6 is enabled. Its scripts program mangle chains through
`iptables -t mangle -w`, `ip6tables -t mangle -w`,
`iptables-restore -T mangle -w -n`, their IPv6 equivalents and `ipset
restore`. It also creates `ip rule` entries for per-WAN routing tables.

The pinned OpenWrt iptables package defines `iptables-nft` and
`ip6tables-nft` as the default providers for the `iptables` and
`ip6tables` virtual packages. Both use `xtables-nft`; that package depends
on `kmod-nft-compat`. This means mwan3's xtables commands are translated to
nf_tables rules, rather than using the legacy xtables backend, and can coexist
with firewall4's native nftables rules. The image config now selects these
providers and the required ipset/extensions explicitly; the image verifier
checks their presence.

This is a package/API compatibility result, **not** runtime proof. Before
calling the firewall integration validated, the target router must pass all
of the following with firewall4 running and both WAN interfaces online:

1. `iptables --version` and `ip6tables --version` both report
   `nf_tables`.
2. Starting mwan3 creates `mwan3_hook` in IPv4 and IPv6 mangle tables,
   without errors in `logread`.
3. `ipset list -name` shows the mwan3 IPv4/IPv6 sets; the nft ruleset shows
   both the firewall4 table and the xtables-managed mangle tables.
4. `mwan3 status` reports the expected logical interfaces as online, and
   `ip -4 rule` / `ip -6 rule` show mwan3's fwmark lookup rules.
5. Repeated interface ifdown/ifup, mwan3 restart and cable-pull failover
   leave the firewall4 ruleset intact and recreate the mwan3 chains and sets.

Useful capture commands:

```sh
iptables --version
ip6tables --version
iptables -t mangle -S
ip6tables -t mangle -S
ipset list -name
nft list ruleset
mwan3 status
ip -4 rule show
ip -6 rule show
ip -4 route show table all
ip -6 route show table all
logread | grep -Ei 'mwan3|iptables|ip6tables|nft'
```

The generated kernel config must also retain `CONFIG_FIB_RULES=y`,
`CONFIG_IP_MULTIPLE_TABLES=y`, `CONFIG_IPV6=y` and
`CONFIG_IPV6_MULTIPLE_TABLES=y`. OpenWrt's Kconfig sets the IPv6 multiple
routing-table option when IPv6 is enabled; `verify-v2.sh` checks the final
kernel config rather than assuming the defconfig request survived.

## ECM mark classifier and conntrack CLI status

The pinned QSDK 14.0 feed Makefile for `qca-nss-ecm` appends
`ECM_CLASSIFIER_MARK_ENABLE=y` for the `qualcommax` target board. The
PREPARE_ONLY #78 artifact confirms `CONFIG_TARGET_BOARD="qualcommax"`,
`CONFIG_TARGET_SUBTARGET="ipq50xx"` and
`CONFIG_PACKAGE_kmod-qca-nss-ecm=y`. Therefore the build requests the ECM
mark classifier for RD03v2; this is necessary groundwork for mwan3 mark
handling, not proof of runtime correctness or that every fwmark/CONNMARK flow
is NSS-offloaded.

The same prepared `.config` explicitly leaves
`CONFIG_PACKAGE_conntrack` unset. `iptables-mod-conntrack-extra` is only
the xtables/kernel extension; it does not ship the userspace `conntrack`
command. A future selective conntrack-cleanup hook must add the
`conntrack` package from the pinned `conntrack-tools` 1.4.8 package and
must fail closed if the command or mark configuration is missing.

Required hardware evidence before accepting mark-aware NSS Dual-WAN:

1. Generate flows with mwan3 marks on WAN1 and WAN2; record packet captures,
   conntrack marks, `ip rule` selections and ECM/NSS connection counters.
2. Compare ordinary NAT, policy-routed flows, and flows that do not qualify
   for offload. Confirm the selected egress is the one whose WAN-mark is stored.
3. Repeat during tracker `disconnected`, netifd `ifdown`, and rule restore;
   separate old-flow teardown from new-flow placement.
4. Do not interpret classifier selection in a Makefile as proof of an offload
   success. Runtime counters and cable-pull results are mandatory.

Pinned package source:
[`qca-nss-ecm/Makefile`](https://github.com/kuncy7/nss-packages/blob/57c0fa18f847f6cb23992ff3493c6a9131246f4c/qca-nss-ecm/Makefile).
PREPARE_ONLY artifact: [CI #78](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43709621665).

## Required v2 validation

Record image tag, kernel, feed pins, NSS mode, actual WAN logical names,
encapsulation and source prefixes for every run.

| Test | NSS | Topology | Required evidence |
|---|---|---|---|
| Single-WAN baseline | on | WAN1 only, then WAN2 only | throughput, CPU, NSS/ECM counters |
| Baseline comparison | off | WAN1 only, then WAN2 only | isolate NSS-specific behaviour |
| Policy-rule churn | on | both WANs, routed IPv6 if available | TCP upload/download, `ip -6 rule`, route tables, ECM counters |
| Failover IPv4 | on | both WANs | new flows, conntrack/NAT, route and per-WAN counters |
| Failover IPv6 | on | both WANs with real IPv6 | routed flows before/during/after cable pull |
| Route/rule ordering | on | controlled test rig | routes-first vs rules-first restore order |
| Stress | on | two WANs | 800 rule changes / 4.4 s, kernel warnings, memory |
| Weighted balancing | on/off | both WANs | many parallel flows, per-WAN byte counts |
| AWG policy | on | both WANs + AWG | handshake, endpoint reachability, tunnel throughput, ordinary NAT throughput |
| Recovery | on | repeated loss/restore | no stale flow remains pinned to the failed WAN |

A pass is not just a successful ping. Check actual traffic and existing
connections across each transition. Save `ip rule`, `ip route show table all`,
`conntrack -L`, `mwan3 status`, `logread`, ECM/NSS counters and packet
captures where possible.

## ECM v2 candidate validation status

The active candidate is
`feed-overlay/nss/qca-nss-ecm/patches/9002-rd03v2-defunct-ecm-flows-on-fib-policy-rule-changes.patch`.
It is a separate RD03v2/QSDK 14.0 adaptation applied after the pinned ECM feed
patch queue and patch 9001.

The gate-first ECM source candidate was introduced in `16193bfb29eecca103a370270458a779403ac619`; its patch-envelope repair is `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`, and the functional test-harness commit is `0ca5b790cded21107f4ca72b987d3129790a9b18`. The latest test-script change is `5b3328e23d36b2b1089e4b2342e0a5255578e022` (one comment insertion to request full CI, with no test or firmware behavior change). Current patch blob: `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`; current test-harness blob: `dbb7859aed90d1b125de28801dd44d6826d3a2fe`. Code/test HEAD is `5b3328e23d36b2b1089e4b2342e0a5255578e022`; branch HEAD is `ffb68d29abd777bed44cb113887649fe88557698`, with only documentation commits after the code/test checkpoint. A self-audit corrected malformed diff metadata and stray NaN/0 text; strict envelope/hunk checks pass (9 sections, 22 hunks). CI #123/#124 apply and compile evidence belongs to an earlier revision. The current candidate has not been applied to the exact archive, compiled, or fault-injected. The preflight script's presence and source-level assertions are not a substitute for executing it.

No workflow run or successful commit status is associated with the current source/test candidate; Actions API still shows #129 as the latest run. Hardware module lifecycle, FIB churn, mwan3 failover, conntrack behavior, NSS/ECM counters, throughput, CPU, latency, packet loss and recovery on the second RD03v2 are **NOT TESTED**.

### Important behavior limits

The notifier is a broad ECM acceleration invalidation mechanism for policy-rule
ADD/DEL events. It does not migrate conntrack marks, guarantee continuity of
existing NAT/TCP/UDP sessions across different public WAN addresses, or by
itself handle every mwan3 tracker `disconnected` event. The baseline criterion
is that new connections use the surviving WAN; existing sessions must be
measured and documented separately.

The pinned mwan3 2.12.5 audit shows that tracker `disconnected` can update
mangle policy without removing per-WAN `ip rule` entries or routes, so it
does not necessarily emit a FIB rule event. A real netifd `ifdown`/route-rule
removal is a separate test case. Global `flush_conntrack` is not enabled and
must not be used as a substitute for selective cleanup.

A future selective conntrack cleanup feature would need the userspace
`conntrack` command from pinned `conntrack-tools` 1.4.8. The current image
manifest does not select it; `iptables-mod-conntrack-extra` is not a
replacement. Such a feature must validate mwan3 IDs and masks and fail closed,
never falling back to a global flush.

Do not call the firmware production-ready or flash the primary router. A CI
build is not a release: the workflow uses a temporary signing key and
`example.invalid`, and hardware validation has not begun.
