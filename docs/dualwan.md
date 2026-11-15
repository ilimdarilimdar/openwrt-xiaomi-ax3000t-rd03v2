# Dual-WAN baseline for Xiaomi AX3000T RD03v2

This branch adds upstream `mwan3` and `luci-app-mwan3` to the RD03v2 image.
The package selections use the feed revisions pinned in `feeds.lock`:
`mwan3` 2.12.5 from the packages feed and `luci-app-mwan3` from the LuCI
feed. Their declared package dependencies are resolved by OpenWrt Kconfig.

This is a **packaging baseline**, not yet a production-validated Dual-WAN/NSS
firmware. The image has not been built or tested on hardware from this branch.

## What this change does

- Ships the mwan3 daemon and LuCI application in the root filesystem.
- Adds a separate RD03v2 ECM patch 9002 for FIB policy-rule ADD/DEL events.
- The candidate defers rule-change handling from the atomic notifier callback
  to a work item, then invalidates accelerated connections by address family.
- Patch application has passed the pinned-source and feed-series preflight;
  compilation and hardware behavior remain unverified.
- Does not preconfigure WANs. First identify the actual netifd logical interface
  names and DSA port mapping on the target router.

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

The candidate lives at
`feed-overlay/nss/qca-nss-ecm/patches/9002-rd03v2-defunct-ecm-flows-on-fib-policy-rule-changes.patch`.
It is a separate RD03v2 adaptation, applied after the pinned upstream ECM feed
patch queue and RD03v2 patch 9001.

**Verified for the previous source revision (`ac4ee43`):**

- The exact QSDK 14.0 source archive is SHA-256 checked before preflight.
- CI #77 passed application to the clean archive and after all 31 preceding
  ECM feed patches, including 9001.
- The FIB worker uses Linux 6.18 rule ADD/DEL events, per-family pending bits,
  an RTNL snapshot barrier, and v2 temporary frontend-stop helpers.

**Latest source revision (`e80f964`), awaiting CI #82:**

- Adds an exported, idempotent stop helper which unregisters the FIB notifier
  and drains the work item before ECM front-end shutdown.
- Calls the helper in normal module exit and all relevant front-end init-unwind
  paths; retains a fallback call before DB termination.
- Extends preflight assertions to check the shutdown ordering on raw and fully
  feed-patched source.
- CI #78 confirmed the lifecycle preflight on the previous source revision
  `3614994`; its full-build job was still running at the last live inspection.
- Source commit `e80f964` changes the worker to the matching Linux 6.18
  `rtnl_net_lock(&init_net)` API. Updated preflight assertions and Bash quoting
  are queued in CI #82; compile remains NOT VERIFIED.
- CI #77's full-build job failed while compiling `package/feeds/nss/qca-nss-ecm`.
  Its detailed compiler log was omitted from the artifact. The corrected
  workflow now collects `openwrt-v2/logs/package/feeds/nss/**`.

**Still NOT VERIFIED:**

- Compilation of the latest `qca-nss-ecm` patch queue and inspection of the
  resulting `ecm.ko` marker.
- Final image verification on the latest source revision.
- Boot, Dual-WAN failover/load balancing, NSS/ECM counters, throughput, packet
  loss, latency and repeated mwan3/module restart tests on the second router.

Do not call the firmware production-ready or flash the primary router. Keep
the primary device on stock firmware until source verification, build/image
checks and controlled hardware validation are all complete.
