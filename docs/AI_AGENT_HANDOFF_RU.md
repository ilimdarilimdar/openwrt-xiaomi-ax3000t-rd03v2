# Передача проекта следующему ИИ-агенту: Xiaomi AX3000T RD03v2

> Единая точка входа для продолжения разработки. Перед изменением кода сначала сверить branch HEAD, diff и CI. Исторические PASS не переносить на более новые исходники.

**Последняя ревизия:** 2026-11-17.
**Репозиторий:** `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`.
**Рабочая ветка:** `work/rd03v2-dualwan-mwan3-baseline`.
**Source implementation commit:** 16193bfb29eecca103a370270458a779403ac619.
**Latest patch-envelope repair commit:** f9f33b314ef11ad42037ad81de18e05f6e0e11f3.
**Latest functional test-harness/code-test HEAD:** `7a7df3c6228864ccc8f0a5245a637ebacee5b73e`.
**Latest test-harness revision:** `7a7df3c6228864ccc8f0a5245a637ebacee5b73e` (removes redundant duplicated source-preflight and duplicate IPsec self-test; firmware patch/configuration unchanged).
**Current patch blob:** 3dbe8c97bdab7ee7452fc49b4ae77580788ef659.
**Current test-harness blob:** `6c25f32b9b38a3b3e92e0d01d227e34b73fa2e8b`.
**Previous source/test baseline:** 02ee20ec2fe3d8e08fe146360f1bf7ab18eb9791 (new candidate is later and unvalidated).
**Реестр задач:** [OPEN_ITEMS_REGISTER_RU.md](OPEN_ITEMS_REGISTER_RU.md).

## Текущий подтверждённый статус

- New source implementation: `16193bfb29eecca103a370270458a779403ac619`; latest patch-envelope repair: `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`; current test-harness/code-test HEAD: `7a7df3c6228864ccc8f0a5245a637ebacee5b73e`; current test-harness blob: `6c25f32b9b38a3b3e92e0d01d227e34b73fa2e8b`. It checks unconditional work drain and per-family gate cleanup outside the registered-only branch; pins NSS feed `57c0fa18f847f6cb23992ff3493c6a9131246f4c` / qca-nss-clients source `51be82d`; rejects IPSECMGR/XFRM/KLIPS package declarations in both NSS Makefiles; and blocks seven IPsec Kconfig/package selectors. The previously duplicated source-preflight block (760 exact duplicate lines) and repeated IPsec self-test (27 lines) were removed. Full-script bash -n passes. Firmware source, patch 9002 and build configuration were not changed.
- Gate-first callback: the first IPv4/IPv6 event atomically sets a family-gated bit and closes its temporary frontend gate before setting pending state/queueing work. Repeated events coalesce without incrementing the temporary counter again.
- Initial register_fib_notifier replay is handled with a readiness barrier: callback records/gates events but does not queue until registration returns; successful init arms ready and queues one worker.
- Worker drains pending family bits in a loop. It releases gates only after an empty-pending check under per-net RTNL. Teardown disarms, unregisters, cancels/drains work and cleans residual pending/gated references.
- Exact NSS feed IPsec notifier exclusion: project `feeds.lock` pins ADCDS/nss-packages at `57c0fa18f847f6cb23992ff3493c6a9131246f4c`; qca-nss-clients source is `51be82d`; neither qca-nss-clients nor qca-nss-drv Makefile declares IPSECMGR/XFRM/KLIPS KernelPackages. The NSS_NLIPSEC_ENABLE selector derives from NSS_DRV_IPSEC_ENABLE, default n. The harness scans both Makefiles and blocks direct/derived IPsec selectors.
- Exact pinned QSDK 14.0 source SHA `7894b769eeb64f1c44fde547a107a8b866997590` was re-opened from the CodeLinaro mirror. Its tree contains 81 C files; the eight `frontends/cmn/` translation units with `ecm_ipv4_lock`/`ecm_ipv6_lock` acquisitions were reviewed directly. None contains a direct RTNL acquisition or `ASSERT_RTNL*`. `ecm_interface.c` separately uses `rtnl_lock()` for WLAN hook registration, outside a translation unit that acquires either family lock. This is not a whole-program indirect call-graph proof. In particular, packet processing can retain a family lock while `ecm_db_connection_add()` dispatches DB listeners; the standard connection listener reaches `ecm_notifier_connection_added()`, whose external atomic notifier chain is only invoked when a subscriber is registered. The preflight rejects the known IPsec/XFRM Kconfig enable symbols because that subscriber changes the lock-order assumptions. Any new ECM notifier subscriber requires a fresh callback audit. Runtime lockdep/KASAN remains mandatory.
- Latest code/test HEAD is `7a7df3c6228864ccc8f0a5245a637ebacee5b73e`. Last Actions run #129 is on old SHA `e398b3f598b6b4adcabd2e7d99fc5b2c7ce4991b`, cancelled before jobs; the read-only API returns 129 total runs. No workflow run or commit status exists for code/test HEAD `7a7df3c6228864ccc8f0a5245a637ebacee5b73e`. The API does not expose why no run was created; do not assert that repository Actions are currently disabled without a current UI/settings check.
- Manual `workflow_dispatch` exists, but neither `full_build=false` nor `full_build=true` has been run for current HEAD. The available GitHub connection exposes no workflow-dispatch action; maintainer must use the Actions UI and verify workflow/repository enablement.
- Runtime notifier, module load/unload, firewall4/mwan3, conntrack marks, NSS WAN-flow offload, latency/loss/throughput, Warface and soak are **NOT TESTED**.
- CI uses a temporary P-256 key and example.invalid, publishes no installable firmware. Primary router remains on stock MiWiFi.

## Harness de-duplication correction — 2026-11-17

Harness review (2026-11-17): commit `325ac7afd406fcf5a79207a1a1efaeeaad937d60` accidentally introduced a second copy of the source-preflight section. Exact comparison confirmed 759/759 duplicate lines. Commit `d81ab86289ccb0f917aacdf553264554208cc7f3` removes the redundant 760-line tail; `7a7df3c6228864ccc8f0a5245a637ebacee5b73e` removes a second redundant 27-line IPsec self-test. The final script is 1,151 newline-terminated lines; full-script `bash -n` passes, and the source-preflight, RTNL guard, make-variable reader, and IPsec self-test now each occur once. This is a harness correction, not a firmware patch change.

The older Actions run #127 preflight log is historical: it applied the prior 9002 patch with 19 hunks. The current patch blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659` has 22 hunks and therefore requires a fresh exact-source run; do not transfer the old PASS. The latest full-script Bash syntax check is PASS, but the current harness has not yet been executed against the exact QSDK archive and complete feed series.


## Следующие действия

1. Восстановить GitHub Actions на форке и выполнить manual dispatch full_build=false для source/test candidate.
2. Проверить exact QSDK archive apply, полную 32-patch series и Static/PREPARE_ONLY; затем выполнить full_build=true с C compilation, image generation и полным verify-v2.
3. Выполнить fault injection initial replay/retry, IPv4/IPv6 route notifier registration, FIB notifier registration и worker events during defunct pass.
4. Запустить lockdep/KASAN/concurrency/load-unload checks, особенно обратные/косвенные зависимости вокруг RTNL → ECM frontend spinlock; статический guard для прямого RTNL acquisition внутри family-lock critical section не заменяет lockdep.
5. Только после CI/fault/lockdep PASS перейти к hardware тестированию на втором RD03v2 с recovery-процедурой.
6. Не прошивать CI images и не трогать основной домашний роутер.


## Текущая контрольная точка

- Устройство: Xiaomi Mi Router AX3000T **RD03v2**, Qualcomm IPQ5018, 256 MiB RAM, NAND. Не переносить образ на другие аппаратные ревизии.
- OpenWrt/NSS base: `c36db6321c11595dc45a160cdab36b5c2d787744`.
- Kernel package pin: **Linux 6.18.55** (из `target/linux/generic/kernel-6.18`: `LINUX_VERSION-6.18 = .55`).
- QSDK 14.0 ECM source: `7894b769eeb64f1c44fde547a107a8b866997590`.
- NSS feed: `57c0fa18f847f6cb23992ff3493c6a9131246f4c`; packages feed: `3a4f118a016af8a250fc77bb51b92aa2daf91f0a`.
- QSDK source archive SHA-256: `a4d5f4c4a6c4bfac3ded4af993c88249f7afc4444ed78368f367eda4ef231886`.

### GitHub Actions

- [#107](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729849069) и [#108](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729952928): Static/PREPARE_ONLY проходили, но полный `make` остановился на применении ECM patch 9002 после pinned NSS feed patch queue. До компиляции `qca-nss-ecm` дело не дошло. Это не доказательство ошибки C-компилятора.
- Ранний PASS workflow [#106](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729319036) не считать достаточным подтверждением: его preflight использовал проверку через `git apply`, тогда как фактическая сборка использует OpenWrt `scripts/patch-kernel.sh` и GNU `patch -f -p1`. Позднейшие реальные build-запуски выявили расхождение.
- [#118](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43757950832), HEAD `981a60a`: Static PASS; raw-source preflight с реальным `patch -f -p1` дошёл до pinned QSDK source и отверг lifecycle hunk в `ecm_init.c`.
- [#119](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43758676305), HEAD `e211beb`: Static PASS; preflight выявил нестабильный контекст `ecm_exit()`.
- [#120](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43759217102), HEAD `558d3ca`: Static PASS и PREPARE_ONLY preparation PASS, но raw patch application FAILED. GNU `patch` сообщил `Not deleting file ecm_db/ecm_db.c as content differs from patch`. Причина — ошибочная строка `index c97f625..0000000 100644`: нулевой новый blob ID помечал файл как удаляемый, хотя hunk добавлял код.
- Исправление в commit `2823543a937edd5883aafa350009be53f68b215e`: удалена только ошибочная `index`-строка.
- [#121](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43761943330), HEAD `2823543`: Static **PASS**, PREPARE_ONLY source preparation **PASS**, raw QSDK patch 9002 **PASS**, full sorted ECM queue of 32 patches **PASS**. Последующий source guard завершился FAIL: `ecm_db_fib_rule_notifier_stop()` был вставлен после `ecm_conntrack_notifier_stop(1)` в `ecm_exit()`, так что worker мог остаться активным во время normal frontend shutdown. Компиляция не запускалась.
- Исправление в commit `693e8f593bea05a0a6f56266d7c7b60e0622c494`: двухстрочный hunk всё ещё дал неправильный порядок normal-exit teardown; кроме того, его DEBUG_INFO context содержал двойное экранирование newline и не совпадал с исходником.
- [#122](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43762283467), HEAD `693e8f5`: Static **PASS**, PREPARE_ONLY preparation **PASS**, raw QSDK patch 9002 **PASS**, full sorted ECM queue of 32 patches **PASS**; lifecycle guard **FAIL**: FIB worker stop was still not placed before normal frontend shutdown. Full build skipped.
- Исправление в commit `c875a7f71c28209118f5668ae823d78e4e1433d5`: hunk расширен до восьми исходных строк вокруг `ecm_exit()`; в DEBUG_INFO contexts оставлен один обратный слеш перед `n`, как в QSDK source. Это исключает зависимость от полностью проигнорированного контекста при GNU patch fuzz до 2. Требуется подтвердить CI.
- [#123](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43762558933), HEAD `c875a7f`: Static **PASS**, PREPARE_ONLY preparation **PASS**, raw QSDK patch 9002 **PASS**, полная очередь 32 ECM-патчей **PASS**; FIB notifier init/unwind/normal-exit ordering **PASS**; worker drain перед frontend teardown **PASS**; atomic-callback guards **PASS**. Это подтверждает применение и source-level lifecycle guards, но не C-компиляцию ECM.
- [#124](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43762944141), HEAD `bb3d25b`: Static/PREPARE_ONLY, полный 32-патчевый ECM preflight и lifecycle guards **PASS**. Полная сборка завершилась: qca-nss-ecm скомпилирован, оба образа созданы, FIB notifier marker найден в ecm.ko. Финальный verify-v2 завершился **FAIL** на watchdog suite и двух ECM source fingerprints после AUTOREMOVE; детали и последующие исправления записаны ниже.
- Preflight воспроизводит pinned `scripts/patch-kernel.sh`: `${PATCH:-patch} -f -p1` отдельно к чистому QSDK archive и последовательно после всей сортированной очереди ECM feed patches. Оба пути и все lifecycle guards прошли в #123.
- История full-build [#16](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686188656): image generation и package assembly завершились; старый `verify-v2` показал 6 отказов. Artifact logs установили причины: watchdog harness остановился с `qemu-aarch64 is needed`; migration host-shell прогнал 8 тестов PASS, а target BusyBox прогнал 8 ERROR из-за отсутствующего `qemu-aarch64`; 4 DTB checks не нашли `fdtget`. Это ошибки host verification environment, не компиляции ECM и не утверждение о неверном поведении функций.
- В CI #124 шаг `Install image verification host tools` завершился PASS; `qemu-user` и `device-tree-compiler` были установлены до `./build.sh`. Это устранило конкретные host-tool блокеры из старого #16. Сам `verify-v2` #124 был выполнен, но завершился FAIL на watchdog и двух ECM source fingerprints; подробности и последующие фиксы приведены в актуальном checkpoint ниже.
- Kconfig продолжает выводить три unrelated recursive-dependency diagnostics (Qt5 GUI, fwknopd/LuCI fwknopd, squeezelite-custom); `defconfig` завершается, эти пакеты не выбраны. Это не причина отказа 9002.
- Полная C-компиляция `qca-nss-ecm`, marker в собранном `ecm.ko` и image generation подтверждены в CI #124. Final `verify-v2` #124 — **FAIL**. Runtime загрузка модуля, FIB churn и Dual-WAN/NSS hardware tests остаются **NOT TESTED**. Главный домашний роутер остаётся на штатной MiWiFi.

### Linux 6.18.55 source/API review

- Exact stable source reviewed: `gregkh/linux` tag `v6.18.55`, `net/core/fib_rules.c`. `fib_newrule()` and `fib_delrule()` take `rtnl_net_lock(net)` when `rtnl_held == false`, and call the FIB rule notifier while that lock is held. Worker acquisition of `rtnl_net_lock(&init_net)` therefore waits for a normal live init_net rule update to finish before clearing its pending bits.
- The in-kernel VRF path calls `fib_newrule()/fib_delrule(..., true)`; the same pinned `net/core/rtnetlink.c` wraps `__rtnl_newlink()` in `rtnl_nets_lock()/rtnl_nets_unlock()`, which includes the target network's per-net RTNL lock. This covers the `rtnl_held` exception in the reviewed in-tree caller.
- FIB notifier dispatch uses `atomic_notifier_call_chain()`. In the current gate-first candidate the callback closes the affected family frontend gate, records its pending bit and queues work only after initial replay is complete. `atomic_notifier_chain_unregister()` synchronizes with in-flight callbacks through RCU; `cancel_work_sync()` then drains deferred work before ECM teardown.
- Worker releases RTNL before `synchronize_net()` and before ECM DB traversal. The affected frontend stop gate is raised before the network-reader grace period.
- `register_fib_notifier()` performs an initial FIB dump that replays existing rules as ADD events. This can queue one broad family-specific defunct pass during ECM initialization; test module load/reload ordering and impact. Do not label this a defect without runtime evidence.
- This is source/API review only. It does not prove the exact ECM module compiles, that module lifecycle is safe under stress, or that NSS offload and mwan3 failover work on the router.

### Configuration status

- PREPARE_ONLY selects `mwan3`, `luci-app-mwan3`, `kmod-qca-nss-ecm`, NSS DWMAC helper, `iptables-nft`, `ip6tables-nft`, `xtables-nft` and `ipset`.
- Pinned generic kernel config enables `CONFIG_FIB_RULES`, `CONFIG_IP_ADVANCED_ROUTER` and `CONFIG_IP_MULTIPLE_TABLES`; project config requests IPv6 multiple tables. `verify-v2.sh` checks final built kernel symbols.
- Three unrelated Kconfig recursive-dependency diagnostics remain: Qt5 GUI, fwknopd/LuCI fwknopd and squeezelite-custom. Those packages are unset in final `.config`; the selected NSS cycle is absent after tree patch 0014. Keep warnings visible and re-check after feed changes.

### Next actions

1. Контрольная code/test точка: `7a7df3c6228864ccc8f0a5245a637ebacee5b73e`; active patch blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`, test harness blob `6c25f32b9b38a3b3e92e0d01d227e34b73fa2e8b`. Duplicate source-preflight block removed; full-script Bash syntax PASS. Exact pinned-source preflight, C compile and CI have not run for this code/test HEAD.
2. Получить завершённый full CI именно после транзакционного rollback patch: exact QSDK archive apply, вся 32-patch ECM queue, C compilation `qca-nss-ecm`, image generation и полный `verify-v2.sh` без FAIL. Перед этим maintainer должен восстановить Actions, если репозиторий по-прежнему находится на паузе; затем выполнить manual dispatch `false` и `true`.
3. Отдельно выполнить fault injection отказов IPv4 route notifier, IPv6 route notifier и FIB notifier; проверить first-error propagation, partial-registration cleanup, worker drain и повторную загрузку модуля.
4. Только после успешного CI подготовить второй RD03v2 и recovery-метод. Проверить module load/unload, FIB rule churn, mwan3 tracker `disconnected`, netifd `ifdown`/cable pull, оба WAN, conntrack marks, NSS/ECM counters, throughput, CPU, RTT и loss.
5. Основной домашний маршрутизатор оставить на stock MiWiFi. CI-артефакты с временным ключом и `example.invalid` не прошивать.

### Safety and release limits

The full-build workflow creates a temporary CI-only P-256 signing key and uses the placeholder package URL `example.invalid`; build artifacts are not published as a usable release. **Do not flash a CI image** to either router. A real release needs durable controlled signing, a reachable package repository, verified image hashes and a recovery-tested installation path.

The ECM notifier broadly defuncts accelerated connections for the affected IP family after policy-rule updates. This may return flows to the host path and allow re-acceleration; it does not guarantee preservation of existing NAT/TCP/UDP sessions across different public WAN addresses. Conntrack marks can remain associated with the old WAN. mwan3 distributes/failovers individual flows; it does not bond two WANs into higher bandwidth for one TCP flow.

The pinned mwan3 2.12.5 health tracker `disconnected` event updates mangle policy but does not necessarily delete route rules and trigger the FIB notifier. A real `ifdown`/route-rule removal is a separate test case. Global `flush_conntrack` is not enabled in the sample config and must not be added without evaluating impact on all sessions.

### ECM mark classifier and conntrack CLI audit — 2026-11-15

The pinned `qca-nss-ecm/Makefile` (NSS feed commit
`57c0fa18f847f6cb23992ff3493c6a9131246f4c`) selects
`ECM_CLASSIFIER_MARK_ENABLE=y` for `CONFIG_TARGET_BOARD="qualcommax"`.
PREPARE_ONLY #78 confirms `ipq50xx` and `kmod-qca-nss-ecm=y`; mark
classifier build option is therefore requested. Runtime handling of mwan3
fwmark/CONNMARK still needs hardware verification.
PREPARE_ONLY also confirms `CONFIG_PACKAGE_conntrack` is unset.
`iptables-mod-conntrack-extra` is not the userspace `conntrack` CLI; future
selective flow deletion requires package `conntrack` from the pinned
`conntrack-tools` 1.4.8 and fail-closed mark validation. Details and test
requirements are in the **ECM mark classifier and conntrack CLI status**
section of `docs/dualwan.md`.

---

### ECM worker lock alignment — 2026-11-15

В patch 9002 worker использует `rtnl_net_lock(&init_net)` /
`rtnl_net_unlock(&init_net)`, то же API, что и pinned Linux 6.18.55 FIB rule
operations. При выключенном `CONFIG_DEBUG_NET_SMALL_RTNL` (так настроен
target generic config) header реализует эти вызовы inline через обычные
`rtnl_lock()` / `rtnl_unlock()`; при включённом debug option используются
net-scoped locks. Поэтому для целевой конфигурации это не compile blocker и
worker сериализуется тем же primitive, что и FIB rule updates. Static preflight
проверяет lock snapshot и его release до ECM DB walk. Это source-level guard,
не замена compile и hardware stress tests.

---

### Дополнительная контрольная точка — mwan3 conntrack/failover audit (2026-11-15)

Проверен точный pinned source mwan3 2.12.5 из packages commit
`3a4f118a016af8a250fc77bb51b92aa2daf91f0a`:

- `disconnected` (mwan3 health tracker) обновляет policy mangle chains, но не
  удаляет per-WAN `ip rule` и таблицу маршрутов; сам по себе этот event не
  гарантирует FIB notification для ECM patch 9002.
- `ifdown` удаляет WAN rules/routes и может вызвать FIB notifier.
- mwan3 восстанавливает conntrack mark до policy evaluation и сохраняет новый
  mark в conntrack. Существующее соединение может сохранить старый WAN mark.
- ECM FIB worker инвалидирует NSS/ECM acceleration state, но не переписывает
  conntrack mark.
- `flush_conntrack` в этой версии выполняет глобальный flush через
  `/proc/net/nf_conntrack` и запускается только если действие явно перечислено
  в `list flush_conntrack`; sample config не задаёт его по умолчанию.

Следовательно, patch 9002 нельзя считать полным failover-переключателем для
health-check `disconnected`, а прозрачное сохранение уже существующей TCP/UDP
сессии между публичными WAN не обещается. Базовый критерий — новые соединения
выходят через оставшийся WAN; судьбу существующих conntrack flows нужно
измерять отдельно. Не включать глобальный conntrack flush без стендовой оценки.
См. новый раздел **Failover events, conntrack marks and the ECM notifier** в
`docs/dualwan.md`.

Обязательные отдельные испытания: tracker `disconnected` при интерфейсе netifd
UP; реальный `ifdown`/cable pull; conntrack mark до/после; FIB rule events;
NSS counters; packet captures обоих WAN. Selective conntrack cleanup по mwan3 mark — отдельная будущая функция, пока не реализована.
Для неё требуется добавить userspace package `conntrack` из pinned
`conntrack-tools` 1.4.8: текущий `config/image-must-have.txt` включает
`iptables-mod-conntrack-extra`, но не CLI `conntrack`. Скрипт
`/etc/mwan3.user` запускается через `env -i`, поэтому обязан сам загрузить
UCI (`config_load mwan3`), получить ID интерфейса через mwan3 helper и
вычислить mark через `mwan3_id2mask` с фактическим `mmx_mask`. Пустой/нулевой
ID, недоступную конфигурацию или отсутствующий CLI трактовать как отказ без
очистки; никогда не использовать global flush как fallback.

---

## 1. Сначала понять цель проекта

Цель владельца — отдельная прошивка OpenWrt для **Xiaomi Mi Router AX3000T именно аппаратной ревизии RD03v2**, с сохранением Qualcomm NSS/ECM и последующей работой двух независимых WAN.

Приоритеты, в порядке важности:

1. Сохранить аппаратное ускорение Qualcomm NSS/ECM для обычного NAT и маршрутизируемого трафика.
2. Поднять оба независимых WAN, обеспечить корректный failover и затем балансировать независимые соединения.
3. Максимизировать суммарную пропускную способность двух каналов без потери NSS там, где оно поддерживается.
4. Проверить влияние mwan3/policy routing/fwmark на уже ускоренные ECM-соединения.
5. После устойчивой сетевой основы добавить AmneziaWG/WireGuard и отдельную VPN-политику.
6. Позже разработать выбор WAN для игрового трафика Warface по измеренным RTT, jitter и packet loss, с фильтрацией скачков, гистерезисом и защитой от частых переключений.

**Не путать балансировку с bonding:** mwan3 распределяет отдельные IP-соединения между WAN. Он не складывает два канала в один более быстрый TCP-сеанс. Суммарная скорость выше скорости одного WAN возможна для нескольких независимых потоков.

## 2. Аппаратная и пользовательская исходная точка

Целевая платформа:

- Xiaomi AX3000T RD03v2;
- Qualcomm IPQ5018;
- 256 MB RAM, 128 MB NAND;
- Airoha AN8855, DSA;
- радиомодуль QCN6122 для 5 GHz;
- OpenWrt/NSS-дерево на базе `kuncy7/openwrt-nss-edma`, Linux 6.18;
- ECM из QSDK 14.0 в закреплённой версии проекта.

RD03v2 — не MediaTek RD03/RD23. Образы, device tree, инструкции и процедуры записи от этих ревизий несовместимы. Перед любой операцией с NAND повторно подтверждать маркировку устройства.

У владельца два AX3000T RD03v2. **Основной домашний маршрутизатор остаётся на штатной MiWiFi.** Первые установки и тесты OpenWrt — только на втором устройстве. Не переносить тестовую сборку на основной роутер.

По известным диагностическим данным владельца WAN1 (EVPANET) выдавался как статический IPv4, WAN2 (EVNAT) — через DHCP, ранее отображался /32. Не записывать публичные IP, ключи, пароли или дампы конфигурации в публичный репозиторий. Для WAN2 отдельно выяснить фактическую схему next-hop/on-link; не считать адрес клиента обычным gateway. Рабочий IPv6 от обоих провайдеров ранее не подтверждён: IPv6-тесты пока обозначать `BLOCKED / ISP IPv6 not confirmed`, а не PASS.

Для измерения суммы каналов проверить весь физический тракт. Клиент с интерфейсом 1GbE ограничит тест примерно гигабитом даже при более быстрой сумме WAN. Для тестов выше 1 Gbit/s нужен подходящий 2.5GbE-клиент, порт, кабель и корректная топология.

## 3. Где находится работа

Основной репозиторий-форк:

- `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`
- рабочая ветка: `work/rd03v2-dualwan-mwan3-baseline`
- последний подтверждённый firmware source/config HEAD на момент аудита: `f5e828fa1cceb123fee81a1bafe5c9a71d0a81fb`;
- его сообщение: `nss: fix tab context in IPQ50xx Kconfig patch`;
- последующие commits меняли только CI workflow и документацию; firmware source/config считать неизменными до отдельного source diff review.

Контрольная точка предыдущего инженерного аудита — `88ca871cb02074ede9138563e1f007d53d2fb440`. По GitHub compare рабочая ветка на момент последней сверки содержала 32 коммита после этой контрольной точки. Не ориентироваться на старый SHA из предыдущего мануала: получать HEAD заново.

Последний live GitHub compare (HEAD `d8fdd9a364f2fb3b8205f12504988db8fa95af63`, перед этим docs-only обновлением) показал: `main` на общей точке `14a07fbf317a00d2c592c7ffd262bcc3f4b6328c`; рабочая ветка `ahead_by=121`, `behind_by=0`. Это число включает весь commit history ветки, а не только исходные изменения прошивки. Текущая запись сама является docs-only commit, поэтому число ahead увеличится ещё на один; перед PR/merge сравнение обязательно повторить. `behind_by=0`, дополнительный merge/rebase из `main` сейчас не требуется. **Не сливать main автоматически** и не обновлять upstream pins попутно с текущей задачей.

Главные документы проекта:

- `docs/DEVELOPMENT_MANUAL_RU.md` — инженерный мануал и исходные решения;
- `docs/TEST_PLAN_RU.md` — этапы испытаний и критерии приёмки;
- `docs/CI_BUILD.md` — устройство CI и модель подписи;
- `docs/dualwan.md` — текущая Dual-WAN-база и нерешённые вопросы;
- `docs/ecm-policy-routing-port.md` — исследование переноса FIB-rule notifier из v1 в v2;
- `VALIDATION.md` — аппаратные проверки upstream-порта v2.0.x–v2.1.3. Эти результаты относятся к исходному порту/релизам, а не доказывают работоспособность нашей экспериментальной Dual-WAN-ветки.

## 4. Что уже сделано в нашей ветке

Подготовлены:

- профиль RD03v2 и список обязательных пакетов образа;
- включение `mwan3` и `luci-app-mwan3`;
- nft-backed совместимость для mwan3: `iptables-nft`, `ip6tables-nft`, `xtables-nft`, `ipset` и нужные extensions;
- pinned upstream/feed inputs вместо плавающих `main/master`;
- `build.sh` и завершающая процедура сборки;
- `tools/verify-v2.sh` для проверки итогового дерева/образа;
- скрипты безопасной установки и тестирования signing key;
- GitHub Actions workflow `.github/workflows/rd03v2-validation.yml`;
- документация CI, Dual-WAN, ECM и аппаратных испытаний;
- патч `0014` для RD03v2/IPQ50xx-зависимости `luci-app-nss`, направленный на устранение ненужной legacy-зависимости `nss-tools` и Kconfig-цикла.

Патч 0014 прошёл проверку на актуальном PREPARE_ONLY artifact 14181217573: ранее выбранный NSS Kconfig cycle отсутствует в итоговой конфигурации. Остались три unrelated recursive-dependency diagnostics (Qt5 GUI, fwknopd/LuCI fwknopd, squeezelite-custom); все три пакета не выбраны. Повторно проверять этот результат после изменения feeds, пакетов или patch 0014.

## 5. Историческая запись CI #124 и последующих запусков — 2026-11-16

Рабочая ветка: `work/rd03v2-dualwan-mwan3-baseline`.
Исторический code/test HEAD до транзакционного rollback: `49d3579437389e2ffc111b94a08839ef7bd29ae7`. Текущие source/test SHA указаны в верхнем checkpoint; он имеет приоритет.
`main` указывает на upstream v2.1.3, а рабочая Dual-WAN-разработка ведётся в отдельной ветке. Число ahead/behind считать только по свежему compare, не хранить как постоянную характеристику ветки.

### CI #124 — завершённый запуск (историческая контрольная точка)

[CI #124](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43762944141), HEAD `bb3d25b`:

- Static checks: **PASS** (whitespace/merge-base, shell syntax, Python tools, signing-key helper, RD03v2 config/manifest, private-key guard).
- PREPARE_ONLY: **PASS** (pinned sources/feeds, `make defconfig`, patch preflight).
- ECM preflight: **PASS** — SHA-256 QSDK archive check, raw `patch -f -p1`, затем вся сортированная очередь из 32 ECM feed patches; FIB notifier init/unwind/normal-exit, worker drain и atomic callback guards прошли.
- PREPARE_ONLY artifact `14181217573` скачан и проверен. Итоговая конфигурация выбрала `qualcommax/ipq50xx`, RD03v2 target, `mwan3`, `luci-app-mwan3`, `kmod-qca-nss-ecm`, NSS DWMAC helper и nft-backed xtables пакеты.
- В `defconfig.log` остались три recursive-dependency diagnostics для Qt5 GUI, fwknopd/LuCI fwknopd и squeezelite-custom; эти пакеты не выбраны в финальном `.config`. Выбранный ранее NSS cycle отсутствует после patch 0014.
- `CONFIG_PACKAGE_conntrack` не выбран. `iptables-mod-conntrack-extra` не предоставляет userspace CLI `conntrack`; selective mark-aware conntrack cleanup не реализован.
- Full signed-image build: **COMPLETED**. qca-nss-ecm compiled; both image types were created; marker found in ecm.ko; rootfs count 223 packages. Final `verify-v2`: **FAIL** (watchdog 20 PASS / 26 FAIL; ECM 9001/9002 fingerprints false-negative after AUTOREMOVE). See build artifact `14184373198`.
- Build-log artifact `14184373198` downloaded and inspected; it records the three verifier failures. PREPARE_ONLY artifact `14181217573` confirms `CONFIG_AUTOREMOVE=y`.

Предыдущие итерации #107–#122 выявляли несовпадения контекста GNU patch и порядок lifecycle teardown. Они являются историей исправления. CI #124 подтвердил source/preflight и C-компиляцию, но не дал final verify PASS. Исправления watchdog и AUTOREMOVE находятся в commits `f372d519`, `0d2aeadb`, `e7846a1` и `49d3579`; новый CI на точном HEAD 49d3579 ещё не найден.

### Следующие действия

Актуальная очередность, критерии закрытия и зависимости задач находятся в [реестре незакрытых задач](OPEN_ITEMS_REGISTER_RU.md). Первый блокер — completed full CI на актуальном code/test SHA; затем watchdog/ECM verifier, безопасный стенд на втором RD03v2, runtime ECM и firewall4/mwan3 failover. Не считать #127 completed build и не прошивать CI artifacts.

**CI-ограничения:** workflow использует временную P-256 signing keypair и URL `example.invalid`; публикуются только логи/конфигурация. CI image нельзя устанавливать как релиз и нельзя прошивать на роутер.

Ссылки: [workflow run #124](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43762944141), [workflow definition](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/blob/work/rd03v2-dualwan-mwan3-baseline/.github/workflows/rd03v2-validation.yml).

## 6. Подпись, CI и безопасность артефактов

Полная CI-сборка намеренно не использует постоянный пользовательский ключ:

- генерируется временная P-256 keypair на одноразовом runner;
- CI использует URL репозитория пакетов `example.invalid`;
- CI публикует диагностические логи/конфигурацию, а не пользовательский релиз;
- такой образ не предназначен для установки в домашнюю сеть.

Постоянный приватный signing key:

- не помещать в Git;
- не отправлять в чат и не печатать в логах;
- не создавать заново и не менять публичный ключ без решения владельца;
- не подменять временным CI-ключом;
- использовать только локально/в доверенном окружении для реального подписанного релиза.

Не считать успешную компиляцию релизом. До релиза отдельно проверить image profile, factory/initramfs и sysupgrade artifacts, SHA-256, rootfs package manifest, kernel/modules/vermagic, публичный ключ, реальный package repository URL и release notes.

## 7. Главные технические блокеры

### 7.1. NSS Kconfig cycle

В предыдущем успешном PREPARE_ONLY были четыре recursive-dependency diagnostics. Три затрагивали необязательные пакеты, отсутствовавшие в итоговом `.config`; NSS-цикл затрагивал выбранный NSS UI/kernel path.

Upstream уже содержит исправление OpenWrt #25091 (commit `87215b42ce7cfd2f43a9423788184a74e09917f0`). Не портировать его повторно. Локальный патч 0014 удаляет legacy fallback `nss-tools` в IPQ50xx-only форке. Проверить generated Kconfig после применения патча и определить, исчез ли именно NSS recursive cycle. Остальные предупреждения описать по источнику и реальному влиянию, не скрывать их.

### 7.2. ECM FIB-rule notifier и mwan3

В v1.14 был FIB-rule notifier (PR #40 / patch 0030), который defunct-ит ускоренные соединения при изменениях policy rules. В текущей v2-линии этот notifier не портирован. API, locking, callback context и lifecycle ECM в v2 отличаются. Не копировать v1 patch вслепую.

До портирования:

1. Получить точный ECM source archive, закреплённый в NSS feed Makefile, и проверить SHA-256.
2. Сопоставить затрагиваемые функции v1 и v2, notifier API, front-end stop helpers, workqueue и cleanup.
3. Подготовить отдельный патч после существующей очереди; не перезаписывать и не перенумеровывать upstream patches.
4. Собрать ECM-модуль под точные pinned Linux 6.18/NSS inputs.
5. Добавить статические проверки регистрации notifier и затем аппаратные тесты.
6. Сравнить stock ECM и patched ECM на policy-rule churn, routes-first/rules-first, restart mwan3, кабельном failover и доступных IPv4/IPv6 сценариях.

Пока это не сделано, Dual-WAN/NSS остаётся **NOT VALIDATED**.

### 7.3. Firewall4 / mwan3 / nft

Наличие `mwan3` в manifest и то, что OpenWrt предоставляет `iptables-nft`, подтверждают только уровень конфигурации/пакетов. На устройстве ещё нужно убедиться, что создаются mwan3 mangle chains/ipsets, правила fwmark и routing tables, а циклы ifdown/ifup и restart не ломают firewall4.

### 7.4. IPv6

IPv6 у двух домашних WAN ранее не был подтверждён. Пока основной acceptance path — IPv4. Не ставить IPv6 failover в PASS без реального адреса, маршрута и трафика от провайдера.

## 8. Приоритетный план следующей работы

Работать последовательно, не смешивать изменения разных уровней.

### Шаг A — завершить и классифицировать текущий CI

1. Сверить текущий branch HEAD, `main` ancestry и run #16/#35.
2. Получить полный список jobs/steps и дождаться завершения #16 либо установить точную причину провала.
3. Если #16 завершился: забрать build logs, выделить первый реальный FAIL, отличить исходниковую ошибку от лимита RAM/disk/time runner.
4. Просмотреть PREPARE_ONLY артефакт последнего HEAD (#29 или более нового run), прежде всего `defconfig.log`, `config.final.txt`, `diffconfig.txt`, `tmp/.config-package.in`.
5. Записать короткий результат в этом документе и в CI_BUILD.md, если он меняет общий статус.

### Шаг B — доказать подготовку актуального дерева

Критерии PASS:

- все upstream и feeds совпадают с pins;
- все tree patches накладываются без fuzz;
- overlay не перезаписывает upstream-файлы;
- `make defconfig` завершается успешно;
- выбран один целевой RD03v2 device;
- сохраняются NSS 256 MB profile, IPv6 kernel symbols, mwan3/nft пакеты;
- нет необъяснённого NSS Kconfig cycle;
- все значимые diagnostics классифицированы и сохранены.

При FAIL сначала диагностировать preflight; не запускать полную компиляцию поверх непонятного Kconfig состояния.

### Шаг C — полная компиляция

После успешного актуального preflight выполнить контролируемую полную сборку. Отдельно зафиксировать download, make, package indexing, image creation и `verify-v2.sh`. Убедиться, что sysupgrade image и factory/initramfs installer присутствуют, manifest берётся из rootfs образа, все проверки PASS.

CI-образ на temporary key/`example.invalid` годится как доказательство сборки и проверки, но не как инсталляционный файл.

### Шаг D — одиночный WAN и NSS на втором устройстве

После выпуска корректного тестового артефакта и подготовки восстановления проверить каждый WAN по отдельности. Снять speed, CPU, RAM, NSS/ECM counters с offload on/off. Не переходить к mwan3, пока не понятна базовая работа каждого WAN и NSS.

### Шаг E — failover до балансировки

- firewall4 + mwan3;
- проверить `iptables --version` / `ip6tables --version` = `nf_tables`;
- проверить chains, ipsets, `mwan3 status`, `ip rule`, routing tables;
- тестировать физическое отключение каждого WAN и отдельную потерю upstream reachability;
- фиксировать source IP, новые и существующие соединения, conntrack, route restoration, logs и ECM counters;
- повторять интерфейсные reload/restart.

Сначала failover, потом weighted balancing. Не пытаться одновременно решить Dual-WAN, ECM porting, AWG и game optimizer.

### Шаг F — балансировка нескольких потоков

Использовать несколько независимых потоков, per-WAN byte counters и подходящий 2.5GbE test path. Проверить общую пропускную способность, потери, CPU и latency под нагрузкой. Один поток не считать тестом агрегации каналов.

### Шаг G — ECM, VPN и Warface

После базового failover проверить необходимость и корректность ECM notifier. Затем AmneziaWG с проверкой endpoint reachability, MTU, маршрутов, CPU и failover. В самом конце — отдельный контроллер качества WAN для Warface: сглаженные измерения RTT/jitter/loss, hysteresis, минимальный dwell time и отсутствие flapping.

## 9. Неприкосновенные правила для следующего агента

1. Не прошивать основной роутер. Тестировать только второй RD03v2.
2. Не выполнять запись NAND, sysupgrade, UBI/MTD-команды и необратимые операции без повторной проверки образа, модели, восстановления и явного решения владельца на этапе установки.
3. Не путать RD03v2 Qualcomm с RD03/RD23 MediaTek.
4. Не менять upstream pins без отдельного diff review и плана регрессии.
5. Не сливать `main` автоматически.
6. Не переносить ECM v1 patch в v2 без анализа точного исходника и компиляции.
7. Не объявлять Dual-WAN рабочим по факту наличия mwan3 в образе.
8. Не объявлять NSS активным по факту наличия пакетов: нужны counters и измерения.
9. Не выдавать PREPARE_ONLY за полную сборку, а CI build — за аппаратный тест.
10. Не раскрывать private keys, VPN credentials, пароли, публичные IP и приватные диагностические дампы.
11. Не скрывать FAIL/WARN и не подменять NOT TESTED на PASS.
12. Все серьёзные изменения делать минимальными, атомарными и документированными.

## 10. Формат записи после каждого продолжения

После любой существенной сессии обновлять раздел журнала ниже. Записывать только проверяемое:

- дата/время UTC;
- branch и полный HEAD SHA;
- что изменено (пути и commit);
- какие команды/actions действительно запускались;
- точный результат каждого теста: PASS / FAIL / NOT TESTED / INCONCLUSIVE;
- ссылки на runs, artifacts и commits;
- известные риски и следующий конкретный шаг.

Не писать «сборка готова», если есть только конфигурация или preflight. Не писать «прошивка работает», если нет аппаратной проверки.

---

## 11. Журнал передачи и продолжения

### 2026-11-15 — исходная передача

- Сверен рабочий репозиторий и ветка; source/config HEAD `f5e828fa1cceb123fee81a1bafe5c9a71d0a81fb`. GitHub compare: рабочая ветка `ahead_by=52`, `behind_by=0` относительно `main` на `14a07fbf`.
- Создана эта опорная запись для будущих ИИ-агентов.
- #15: static PASS + PREPARE_ONLY PASS; artifact ID `14150612353` скачан и исследован, NSS cycle подтверждён; #16: static PASS, full build IN PROGRESS; #29–#34 отменены новыми push; #35 ожидает #16.
- Добавлен `paths-ignore` для Markdown/docs-only изменений (commit `4a0a914`) и исправлен неверный путь к patch 0014 в static validation (commit `472ed0c`).
- Обновлён `docs/CI_BUILD.md` с результатами исследования artifact #15 и текущими CI blockers.
- Подтверждено отсутствие аппаратной валидации нашей Dual-WAN-ветки.
- Создана эта опорная запись: commit `8039a4795cc66434e17deca5f76d0e9e8a1d4fc8`.
- В корневой README добавлена ссылка на неё: commit `331ce2f8328c900bd777b426e098c2450e2f0c06`.
- Эти документационные commits меняют только документацию; firmware source state на момент аудита оставался `f5e828f`.
- Patch 0014: ручная проверка `git apply --check` против точного upstream Makefile из `c36db6321c` завершилась PASS без fuzz; Kconfig-результат пока NOT TESTED.
- Обновлён `docs/CI_BUILD.md` с фактической проверкой применимости patch 0014 (commit `16b0136`).
- Создан кандидат ECM patch 9002 в `feed-overlay/nss/qca-nss-ecm/patches/`; он использует v2 temporary frontend stop helpers и deferred worker. Статус: NOT TESTED до pinned archive preflight и compile.
- В patch 9002 добавлен RTNL publication barrier с snapshot/clear pending bits под RTNL; ECM database walk выполняется после unlock. Источники Linux 6.18 подтверждают порядок rule ADD/DEL. Добавлена статическая проверка именно этого порядка; до запуска актуального CI патч всё ещё NOT APPLY-VALIDATED / NOT COMPILED.
- Создан `tools/test-ecm-fib-rule-patch.sh`: проверяет PKG_HASH, `git apply --check`/apply и assertions for callback/worker/teardown. Workflow PREPARE_ONLY вызывает этот script.
- `verify-v2.sh` проверяет runtime notifier marker внутри `ecm.ko` в финальном sysupgrade rootfs; ECM patch fingerprints проверяются по всему source tree.
- CI snapshot на момент последней API-проверки: #16 IN PROGRESS на старом source commit; #43–#56 CANCELLED последующими push; #57 PENDING на актуальном code HEAD `6878d6d` и содержит свежие patch/preflight проверки.
- Проверен diff #57 (`6878d6d`): исправлены две C-строки `DEBUG_TRACE` на корректный `\n`; это исправление диагностики, алгоритм не меняет. #16 всё ещё IN PROGRESS; #57 WAITING за ним.
- Обновлены `docs/ecm-policy-routing-port.md`, `docs/CI_BUILD.md`, `docs/DEVELOPMENT_MANUAL_RU.md` и этот handoff.
- Следующий шаг: проверить результаты #16 и #57. Для актуального patch 9002 нужны PASS pinned archive preflight, анализ `.config`/Kconfig, затем компиляция ECM с полной feed patch series и проверка runtime marker; ни один из этих критериев пока не пройден на актуальном code HEAD.



**Примечание к документационным обновлениям:** этот файл намеренно является живой записью. Любой следующий агент должен сохранять исторические SHA как контрольные точки, но всегда запрашивать актуальные refs и CI state из GitHub. Последующий сдвиг branch HEAD от обновления этого же файла — ожидаемый docs-only commit, не доказательство изменения firmware code.

### 2026-11-15 — дополнительная проверка upstream FIB notifier API (Linux 6.18)

- Повторно сверены первоисточники Linux v6.18: `net/core/fib_notifier.c`, `kernel/notifier.c`, `net/core/fib_rules.c`, `net/ipv4/fib_notifier.c` и `net/ipv6/fib6_notifier.c`.
- Подтверждено: FIB notifier использует `atomic_notifier_call_chain()`; callback обязан быть неблокирующим. В patch 9002 callback только устанавливает pending bit и вызывает `schedule_work()`, что соответствует atomic-context контракту.
- Подтверждено: изменения fib rules отправляются через путь с `ASSERT_RTNL_NET(net)`. Worker берёт RTNL только для snapshot/очистки pending bits и освобождает его до обхода ECM DB; по исходникам это согласуется с порядком завершения rule update.
- Подтверждено: `unregister_fib_notifier()` в итоге вызывает `atomic_notifier_chain_unregister()`, а та выполняет `synchronize_rcu()`; последующий `cancel_work_sync()` дожидается завершения отложенной работы. Это подтверждает ожидаемую синхронизацию callback/work при teardown на Linux v6.18.
- **Нюанс, который надо тестировать:** `register_fib_notifier()` сначала вызывает initial FIB dump. IPv4/IPv6 dump включает существующие policy rules как `FIB_EVENT_RULE_ADD`; текущий callback patch 9002 не отличает initial dump от реального изменения и поэтому может поставить один общий defunct pass при инициализации ECM. Вероятно, это безвредно при обычной загрузке до появления accelerated flows, но следует проверить порядок и побочные эффекты при старте/перезагрузке ECM; не объявлять это дефектом без теста.
- Статус: **source/API review PASS для изученных контрактов; compile/runtime/hardware остаются NOT TESTED**. Проверка основана на upstream Linux v6.18, но не заменяет сборку точного pinned QSDK ECM source и аппаратный тест.
- Источники: https://github.com/torvalds/linux/blob/v6.18/net/core/fib_notifier.c ; https://github.com/torvalds/linux/blob/v6.18/kernel/notifier.c ; https://github.com/torvalds/linux/blob/v6.18/net/core/fib_rules.c ; https://github.com/torvalds/linux/blob/v6.18/net/ipv4/fib_notifier.c ; https://github.com/torvalds/linux/blob/v6.18/net/ipv6/fib6_notifier.c .


### 2026-11-16 — архивный PREPARE_ONLY snapshot перед завершением #124

- На тот момент code/test HEAD был `bb3d25b8d80844cd32d5bb71ec1bb090f286bc10`; более актуальная сводка находится в верхнем блоке этого handoff и в следующем разделе post-build audit.
- CI #124 подтвердил Static/PREPARE_ONLY, QSDK source apply, полную 32-патчевую ECM очередь и lifecycle/atomic callback guards.
- PREPARE_ONLY artifact `14181217573` подтвердил RD03v2 `qualcommax/ipq50xx`, mwan3/LuCI mwan3, NSS/ECM, DWMAC helper, nft-compatible пакетный набор и `CONFIG_AUTOREMOVE=y`. Три unrelated Kconfig diagnostics относятся к невыбранным Qt5 GUI, fwknopd/LuCI fwknopd и squeezelite-custom.
- Userspace `conntrack` CLI не включён; selective conntrack cleanup по WAN mark остаётся будущей отдельной функцией.
- Последующее завершение full build и final verifier зафиксировано ниже: сборка ECM и image generation прошли, но verify-v2 завершился FAIL на трёх проверках.
- Основной роутер остаётся на stock MiWiFi; аппаратные Dual-WAN тесты не запускались.

### 2026-11-16 — post-build audit, CI #125–#129 и текущее состояние

- Исторический post-build audit начинался с code/test SHA `49d3579437389e2ffc111b94a08839ef7bd29ae7`; последующие транзакционные notifier rollback и regression guards указаны в верхнем актуальном checkpoint.
- CI #124: full build дошёл до конца сборки, создал sysupgrade и initramfs-factory images, собрал `qca-nss-ecm`, включил `kmod-qca-nss-ecm` и marker FIB notifier в `ecm.ko`. Финальный workflow завершился FAIL на трёх проверках verifier; это не compiler failure. Artifact `14184373198`; rootfs — 223 пакета.
- Три FAIL в #124: watchdog `--check` (20 PASS / 26 FAIL), fingerprint ECM 9001 и fingerprint ECM 9002. Watchdog test fix: `f372d519` добавил `wd_command` с абсолютными путями stubs в `--check`; `0d2aeadb` передаёт `WD_TEST_STUB_DIR` в harness и Q6 policy step.
- CI #125 (`f372d519`) и #126 (`0d2aeadb`) провалили только `git diff --check`: лишняя пустая строка в конце `docs/AI_AGENT_HANDOFF_RU.md`. `prepare-only` и `full-build` были skipped; watchdog scenarios не выполнялись. Commit `e31ca88` удалил лишнюю строку.
- CI #127 (`faa82e24`): Static checks **PASS**, PREPARE_ONLY **PASS**, в том числе QSDK source preflight и полный порядок ECM patch queue. Full-build запустился, создал временную P-256 signing pair, вошёл в `./build.sh`, но runner получил shutdown; процесс завершился кодом 143. Это **не** compile PASS и **не** результат `verify-v2`. Preparation artifact: `14185375390`.
- CI #128 (`e7846a1`) и #129 (`e398b3f`) были отменены до создания jobs.
- AUTOREMOVE fingerprint fix в `e7846a1`: verifier проверяет наличие настоящего `ecm_db/ecm_db.c`, а не только каталога; если исходники удалены, сравнивает exact patch files в подготовленном NSS feed. Commit `49d3579` добавил guard: fallback принимается только если `.config` содержит ровно `CONFIG_AUTOREMOVE=y`. Оба изменения ещё не проходили завершённый full build на актуальном code/test HEAD.
- Live lookup по SHA `49d3579` возвращает ноль workflow runs и пустые commit statuses. Поэтому watchdog runtime suite после абсолютных stubs и AUTOREMOVE verifier fallback/guard остаются **NOT CI-VALIDATED**. Статические проверки и PREPARE_ONLY #127 — отдельное, более узкое подтверждение.
- Никакие текущие commits не доказывают безопасную загрузку/выгрузку ECM на железе, Dual-WAN failover или сохранение NSS throughput. Hardware status — **NOT TESTED**. Главный роутер не прошивался и остаётся на stock MiWiFi.
- Дальше: получить полный CI run на точном актуальном code/test HEAD; проверить runtime watchdog suite, ECM compile, image verifier и manifests; затем подготовить только второй RD03v2 к аппаратным тестам с recovery-планом. CI artifacts используют disposable signing key и `example.invalid`; **не прошивать** их.

### Уточнение по fuzz при применении ECM patch 9002 — 2026-11-16

В реальном compile log CI #124 GNU patch сообщил fuzz при применении 9002: ecm_db/ecm_db.c hunks #1/#2/#4 — fuzz 1/1/2; ecm_init.c hunks #2/#4 — fuzz 1/2. В частности, ecm_init.c hunk #4 вставляет FIB notifier stop в ecm_exit(). Поэтому нельзя описывать фактическое применение 9002 как полностью fuzz-free.

Это не доказывает неправильное расположение вызова. PREPARE_ONLY script test-ecm-fib-rule-patch.sh воспроизводит сортированную очередь feed patches точной операцией patch -f -p1, а затем анализирует pristine-patch результат и результат полной серии. Lifecycle guard требует ровно один ecm_db_fib_rule_notifier_stop() в ecm_exit(), непосредственно перед DEBUG_INFO("stop conntrack notifier\n"), и проверяет, что stop находится раньше conntrack/frontend teardown. В CI #124 PREPARE_ONLY и lifecycle guards прошли. Фактическая сборка использовала те же pinned source и patch order.

Остаточный статус: положение кода проверено на уровне исходников и статических guards, но module load/unload, runtime teardown stress и аппаратное поведение остаются NOT TESTED. Компилятор также выдал некритичные warnings: неиспользуемая метка init_cleanup_1 и отсутствующий MODULE_DESCRIPTION(); они не помешали сборке ecm.ko.


### Lock-order audit for ECM-06 — 2026-11-16

- Exact QSDK ECM source revision: `7894b769eeb64f1c44fde547a107a8b866997590`. GitLab repository tree lists 81 C files; do **not** claim that every file was individually downloaded and reviewed. Direct review covered the eight `frontends/cmn/` translation units with IPv4/IPv6 family-lock acquisitions, plus `ecm_interface.c`, `ecm_db_connection.c`, `ecm_db.c`, `ecm_db_listener.c` and `ecm_notifier.c`.
- The eight reviewed family-lock translation units contain no direct RTNL acquisition or `ASSERT_RTNL*`. `ecm_interface_register_nf_hook_wlan_device()` in `ecm_interface.c` does use `rtnl_lock()`, but that registration path does not directly acquire an ECM family lock.
- Indirect callback path: packet processing can hold a family lock while `ecm_db_connection_add()` synchronously dispatches the registered DB listener. The standard DB listener's node/host/mapping callbacks are NULL; connection callbacks lead to `ecm_notifier_connection_added/removed`. The add callback returns immediately when `ecm_notifier_count == 0`, before invoking the atomic notifier chain.
- Target configuration evidence: PREPARE_ONLY run #127 artifact `14185375390` (ZIP SHA-256 `5f29e8a7554d2dc035410eedd1fd92c0da615bed348e78ead910ace23c11e0d7`) has `CONFIG_PACKAGE_kmod-ipsec`, `CONFIG_PACKAGE_kmod-ipt-ipsec`, and `NSS_DRV_IPSEC_ENABLE` all unset. The pinned NSS feed does not select/build an IPsec XFRM client package. The known external `nss_ipsec_xfrm_ecm_conn_notify` subscriber is therefore not part of this RD03v2 candidate. Re-audit if IPsec/XFRM or another ECM notifier subscriber is added later.
- `tools/test-ecm-fib-rule-patch.sh` guard rejects direct RTNL acquisition/assertions anywhere in a translation unit that acquires an ECM family lock; this avoids the old first-unlock/alternate-branch blind spot. Local synthetic tests PASS for no direct call, comment/string filtering, alternate-branch detection, `ASSERT_RTNL`, and a direct call in another function of the same translation unit.
- The ECM preflight also rejects a prepared `.config` that selects `kmod-ipsec`, `kmod-ipt-ipsec`, or `NSS_DRV_IPSEC_ENABLE`, because that would change the external-notifier assumption. Guard-fragment `bash -n` and behavior tests PASS against the actual run-#127 `config.final.txt`: current disabled config passes; synthetic `=m` for each of the three symbols is blocked; explicit disabled symbols pass. The script now self-tests the regex for all three symbols before reading the final config.
- These are source/configuration checks only. Full shell harness, fresh exact-archive apply, C compile, indirect external callback inventory, lockdep/KASAN, fault injection and hardware runtime remain **NOT TESTED**.


**Historical pre-de-duplication code/test checkpoint — 2026-11-16 (superseded by the following section):** the test harness at this checkpoint was commit `1cfd97c5f53ef5d4e9c3452ee8d94a764d24e9bb`, blob `60d7522c876d758fcfd2e0b0e33eda7c17c30080`. The guard now has in-script parser self-tests for string/character literals, comments, alternate unlock branches, `ASSERT_RTNL`, another function in the same translation unit, and a clean case; it still conservatively rejects direct RTNL use anywhere in a TU containing family-lock acquisition. The IPsec/XFRM Kconfig gate self-tests all three forbidden symbols and explicit disabled settings. Local exact Python guard-block tests PASS, clean source fixture PASS, synthetic inversion is detected; `bash -n` and the config fragment tests PASS for the run-#127 config and all three synthetic `=m` toggles. Commits after this source/test checkpoint are documentation-only. The full ECM preflight, fresh exact-archive apply, full feed series, C compile, lockdep/KASAN, fault injection and hardware runtime remain **NOT TESTED**. GitHub Actions still shows `#129` as latest, cancelled before jobs; no later run/check exists for this code/test revision.

### 2026-11-16 — ECM preflight harness de-duplication

- Working-branch code commit: `0ca5b790cded21107f4ca72b987d3129790a9b18`; parent: `7a278b12690f00a82717ce19e7aeb3f511db683c`.
- Changed only `tools/test-ecm-fib-rule-patch.sh`. The file was reduced from 3,134 to 930 lines by retaining the canonical first 923 lines and removing 2,211 lines of orphaned/duplicated tail content. Existing atomic-stop, IPsec/XFRM, RTNL, FIB callback, worker drain, lifecycle and full-patch-queue checks in the canonical block were retained.
- Added explicit checks that the sorted ECM feed queue contains exactly 32 patches before application; that both local patch 9001 and the current 9002 patch are present; that 9002 is encountered only after 9001; and that exactly 32 patches were applied.
- The update was constructed only after checking the exact prior Git blob SHA `60d7522c876d758fcfd2e0b0e33eda7c17c30080`, the 3,134-line count, the canonical line-923 boundary and uniqueness of the insertion anchors. Post-update GitHub readback confirms blob `221127144eed86b46a564b814b18531808140eff`, 930 lines and all new guards.
- Only the test harness changed; firmware patches, configs, feed pins and build inputs were not changed.
- No Actions run or commit status is currently associated with exact code commit `0ca5b790cded21107f4ca72b987d3129790a9b18`. The workflow file supports push and manual dispatch, but the available connector has no workflow-dispatch action. Therefore shell `bash -n`, fresh exact-archive/32-patch preflight, PREPARE_ONLY, full compile/image generation and `verify-v2` on this exact revision remain **NOT CI-VALIDATED**.
- Do not treat this source edit as a CI PASS. Do not flash any CI artifact; primary router remains on stock MiWiFi and hardware Dual-WAN/NSS tests remain **NOT TESTED**.


### 2026-11-17 — Follow-up: exact Linux 6.18.55 FIB registration/error path

- The project kernel pin is Linux 6.18.55. In that exact stable source, `fib_newrule()` and `fib_delrule()` acquire `rtnl_net_lock(net)` when called with `rtnl_held == false`, and call the FIB rule notifier before releasing the lock. The in-tree VRF caller passes `rtnl_held == true` from a path wrapped by `rtnl_nets_lock()/rtnl_nets_unlock()`. Therefore the worker's per-net RTNL snapshot/final-empty check is serialized with the reviewed live init_net policy-rule update paths. Sources: [fib_rules.c](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_rules.c#L911-L930), [delete path](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_rules.c#L1040-L1102).
- `register_fib_notifier()` performs the initial FIB dump under RCU, then registers the atomic notifier and checks dump consistency. Initial replay callbacks can therefore occur before the register call returns and before RTNL readiness. The patch's `ready` barrier correctly records/gates these events without queueing work; successful initialization arms readiness and schedules the coalesced worker. On failure, DB teardown clears any recorded gate state. Source: [fib_notifier.c](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_notifier.c#L58-L125).
- Exact Linux v6.18.55 registration failure semantics were checked in `net/core/fib_notifier.c`: initial `fib_net_dump()` callbacks run before live atomic-chain registration. A dump error returns immediately without attaching the notifier, although earlier replay callbacks may already have set ECM pending/gated state. On a successful dump Linux attaches the atomic notifier and checks the FIB sequence; a mismatch removes the notifier (atomic unregister performs `synchronize_rcu()`) and retries, at most five attempts, after which registration returns `-EBUSY`. Therefore failed-registration cleanup must clear replay-created gate bits even when `registered` is still false; successful teardown must unregister before `cancel_work_sync()`. The current patch follows this order at source level. Exact kernel and notifier references: [fib_notifier.c](https://github.com/gregkh/linux/blob/v6.18.55/net/core/fib_notifier.c#L58-L125), [notifier.c](https://github.com/gregkh/linux/blob/v6.18.55/kernel/notifier.c#L177-L198).
- This review is static. The preflight script checks ECM patch ordering and source guards but does not execute the kernel's five-attempt registration/retry/error state machine. That still needs failure injection or a focused test after the full CI becomes runnable.
- Exact QSDK 14.0 source review confirms an indirect path that must remain explicit in future audits: in the IPv4 ported frontend, `ecm_ipv4_lock` can remain held across `ecm_db_connection_add()`; that function dispatches the DB listener after dropping `ecm_db_lock`; the standard listener calls `ecm_notifier_connection_added()`, which invokes the external atomic notifier chain only when a subscriber is registered. The default listener's node/host/mapping callbacks are NULL. See [ported frontend](https://github.com/CodeLinaro-mirror/qsdk_oss_lklm_qca-nss-ecm/blob/7894b769eeb64f1c44fde547a107a8b866997590/frontends/cmn/ecm_ported_ipv4.c#L783-L846), [DB connection listener dispatch](https://github.com/CodeLinaro-mirror/qsdk_oss_lklm_qca-nss-ecm/blob/7894b769eeb64f1c44fde547a107a8b866997590/ecm_db/ecm_db_connection.c#L3935-L3953), [ECM notifier](https://github.com/CodeLinaro-mirror/qsdk_oss_lklm_qca-nss-ecm/blob/7894b769eeb64f1c44fde547a107a8b866997590/ecm_notifier.c#L173-L194).
- The current harness's IPsec/XFRM config rejection is intentional: a notifier subscriber is an external call path not proven safe merely by grepping the eight frontend translation units. Keep the guard until every selected subscriber is audited. Do not enable IPsec/XFRM as an incidental config change.
- Functional preflight harness/code-test HEAD `7a7df3c6228864ccc8f0a5245a637ebacee5b73e` removes the duplicated 760-line source-preflight tail and redundant 27-line IPsec guard self-test. No firmware patch, config or feed pin changed. Full-script Bash syntax passes; exact pinned QSDK preflight, compile, fault injection, lockdep/KASAN and hardware tests remain **NOT TESTED**.
