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

## Porting checklist

- Extract and hash-verify the exact source archive from the pinned qca-nss-ecm
  package Makefile.
- Check current v2 definitions/call sites for:
  - `ecm_db_connection_defunct_ip_version()`;
  - `ecm_front_end_ipv4_stop()` and IPv6 equivalent;
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
