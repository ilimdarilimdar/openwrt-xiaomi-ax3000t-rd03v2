# Dual-WAN baseline for Xiaomi AX3000T RD03v2

This branch adds the upstream `mwan3` daemon and `luci-app-mwan3` to the
RD03v2 image. The package selections are resolved against the feed revisions
pinned in `feeds.lock`; the image verifier requires both packages to be present.

## What this change does

- Ships mwan3 2.12.5 and its LuCI application in the image.
- Keeps the Qualcomm NSS/ECM source tree and existing patches unchanged.
- Does not add an unreviewed ECM patch or claim that accelerated connections are
  reclassified safely when mwan3 changes policy-routing rules.
- Does not preconfigure either WAN. The physical port-to-netifd mapping differs
  between board configuration and user setup, so the operator must first identify
  the actual logical interface names.

## Important limitation: NSS/ECM and mwan3

The project's validation notes record that issue #36 (ECM/mwan3 IPv6 flow
stall) was not reproduced on the bench, but the current v2 ECM lacks a FIB-rule
notifier. A full mwan3 + PPPoE test rig is still needed to settle the interaction.
Therefore this branch is a **mwan3 packaging baseline**, not an NSS failover fix.

Until the test matrix below passes on the exact RD03v2 hardware and exact image,
do not treat load balancing or failover as production-validated with NSS enabled.
For initial diagnosis, compare behaviour with NSS acceleration enabled and
disabled, and capture both IPv4 and IPv6 results separately.

## Configuration notes

1. Identify the two netifd logical interfaces and their physical DSA devices.
   Do not assume the second interface is named `wanb`; mwan3's UCI section name
   must refer to the actual logical interface name.
2. Configure each WAN independently in `/etc/config/network` first. Verify
   DHCP/static/PPPoE, DNS, gateway and MTU before adding mwan3.
3. Configure mwan3 tracking targets that answer reliably through each ISP.
   Use separate IPv4 and IPv6 tracking only when the provider actually supplies
   working IPv6. This user's two ISP links have not yet been confirmed to provide
   IPv6.
4. Start with failover (different metrics), not load balancing. Confirm that new
   flows move to the surviving WAN after physically disconnecting either uplink.
5. Only after failover tests pass, test weighted per-connection balancing.
   mwan3 distributes flows; it does not bond the links into one faster TCP flow.
6. Test VPN policy separately. AmneziaWG packets are CPU-path traffic on this
   platform; ordinary non-VPN NAT may still use NSS. Do not assume tunnel traffic
   is NSS-offloaded.

## Required validation matrix

Record firmware tag, kernel, feed pins, NSS/ECM mode, WAN interface names and
ISP encapsulation with every run.

| Test | NSS | WAN topology | Expected evidence |
|---|---|---|---|
| Baseline single WAN | on | WAN1 only | NAT throughput, CPU, ECM counters |
| Baseline single WAN | on | WAN2 only | NAT throughput, CPU, ECM counters |
| Failover IPv4 | on | WAN1 + WAN2 | new and established TCP/UDP flows; route and conntrack state |
| Failover IPv6 | on | WAN1 + WAN2 with real IPv6 | same checks, plus ECM IPv6 counters |
| Failover comparison | off | WAN1 + WAN2 | determine whether any stall is ECM-specific |
| Weighted balancing | on/off | WAN1 + WAN2 | many parallel flows, per-WAN byte counters |
| AWG policy | on | WAN1 + WAN2 + AWG | tunnel handshake, endpoint reachability, non-VPN NAT |
| Recovery | on | repeated link loss/restore | no stale flows pinned to failed WAN |

A pass is not just a successful ping. Check actual traffic counters and existing
connections across each transition. Save `ip rule`, `ip route show table all`,
`conntrack -L`, mwan3 status, ECM/NSS counters and packet captures where
possible.

## Scope of this branch

This is intentionally conservative: package integration and documentation only.
An ECM/FIB-rule change must be developed against the exact pinned ECM source,
reviewed, compiled, and validated before it is included in a firmware image.
