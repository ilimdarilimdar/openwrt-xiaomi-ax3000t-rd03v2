# Инженерный мануал проекта Xiaomi AX3000T RD03v2

**Назначение:** единая рабочая инструкция для дальнейшей разработки, сборки, проверки, обновления и эксплуатации собственной прошивки RD03v2 с Qualcomm NSS и экспериментальной конфигурацией Dual-WAN.

**Состояние документа:** 17 ноября 2026 года.

**Репозиторий:** `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`

**Рабочая ветка:** `work/rd03v2-dualwan-mwan3-baseline`
**Текущий SHA:** всегда получать из GitHub перед работой; зафиксированные здесь SHA используются только как исторические точки проверки.

## Происхождение материалов и использование ИИ

Этот форк разрабатывается с использованием ИИ (ChatGPT/Codex). **Все проектные материалы, добавляемые специально в этот форк, включая код изменений, конфигурации, скрипты сборки и тестирования, предложения патчей, технические анализы, описания и мануалы, создаются при помощи ИИ.** Владелец репозитория задаёт цели, направляет работу, рассматривает результаты и принимает решения о принятии изменений, их тестировании, слиянии и установке.

**Атрибуция upstream:** репозиторий является форком проекта ADCDS. Унаследованные исходники OpenWrt/NSS, поддержка устройства, драйверы, сторонние пакеты и работы участников upstream сохраняют авторство их первоначальных разработчиков. Они не объявляются созданными ИИ. Исходные уведомления об авторских правах, благодарности и лицензии сохраняются.

Результат, созданный ИИ, не считается автоматически корректным. Если изменение явно не отмечено как скомпилированное и проверенное на аппаратуре, оно считается непроверенным. Статусы проверки: PASS, FAIL, NOT TESTED и INCONCLUSIVE.

**Текущая инженерная добавка 2026-11-17 (source candidate, ещё не собранная в CI):** patch 9002 code commit 16193bfb29eecca103a370270458a779403ac619 содержит callback-owned IPv4/IPv6 gates, readiness barrier для initial FIB replay, worker drain-loop, RTNL-serialized final release и teardown cleanup. Functional test-harness commit `0ca5b790cded21107f4ca72b987d3129790a9b18` проверяет gate-before-pending, readiness, drain-loop и cleanup; последний comment-only / CI-trigger commit `5b3328e23d36b2b1089e4b2342e0a5255578e022` не меняет поведение harness. Текущий test-harness blob: `dbb7859aed90d1b125de28801dd44d6826d3a2fe`. Self-audit found malformed diff metadata and a stray NaN/0 line in patch 9002; both were repaired in f9f33b314ef11ad42037ad81de18e05f6e0e11f3. Strict envelope/hunk check now passes. Exact archive preflight, full feed series, C compilation, lockdep, fault injection и hardware runtime не выполнены. Не считать candidate исправлением подтверждённым, пока эти проверки не пройдены.

> Это инженерный план, а не сертификат готовности прошивки. Source implementation: `16193bfb29eecca103a370270458a779403ac619`; patch-envelope repair: `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`; functional test harness: `0ca5b790cded21107f4ca72b987d3129790a9b18`; latest comment-only CI-trigger change: `5b3328e23d36b2b1089e4b2342e0a5255578e022`. Current patch blob: `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`; test harness blob: `dbb7859aed90d1b125de28801dd44d6826d3a2fe`. Code/test HEAD: `5b3328e23d36b2b1089e4b2342e0a5255578e022`; subsequent branch revisions are documentation-only. Gate-first callback закрывает family gate до публикации pending bit; initial replay queue откладывается до возврата register_fib_notifier; worker drains pending changes in a loop and releases gate only under RTNL after empty check. Это source candidate: exact QSDK apply, C compilation, full verify, fault injection и lockdep ещё не запускались. #124 собрал предыдущую версию ECM и оба типа образов, но final verify-v2 завершился FAIL; #127 прошёл Static/PREPARE_ONLY, full-build оборван runner shutdown; #128/#129 отменены. После #129 новых workflow runs не видно. Runtime Dual-WAN/NSS на железе не проверялся. CI-артефакты используют временный ключ и example.invalid; они не пригодны для установки. Основной роутер оставить на stock MiWiFi.

### Live status — 2026-11-17

- Source implementation: `16193bfb29eecca103a370270458a779403ac619`; patch-envelope repair: `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`; functional test-harness commit: `0ca5b790cded21107f4ca72b987d3129790a9b18`; latest comment-only CI-trigger: `5b3328e23d36b2b1089e4b2342e0a5255578e022`. Patch blob: `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`; test harness blob: `dbb7859aed90d1b125de28801dd44d6826d3a2fe`. Code/test HEAD: `5b3328e23d36b2b1089e4b2342e0a5255578e022`; later branch changes are documentation-only.
- Pinned OpenWrt/NSS tree: c36db6321c11595dc45a160cdab36b5c2d787744; kernel Linux 6.18.55.
- Pinned QSDK 14.0 ECM source: 7894b769eeb64f1c44fde547a107a8b866997590; archive SHA-256 remains in ECM feed Makefile.
- New gate-first callback, initial-replay readiness barrier and drain-loop are source-committed. Regression harness checks gate-before-pending, ready barrier, worker drain and teardown cleanup.
- Exact archive apply, sorted 32-patch series, C compile, current full verify-v2, lockdep/KASAN and fault injection remain **NOT TESTED**.
- #124 compiled an earlier ECM patch and generated images but final verify-v2 failed (watchdog 20/46, two AUTOREMOVE false negatives). #127 Static/PREPARE_ONLY PASS, full-build interrupted with exit 143. #128/#129 cancelled before jobs.
- Workflow has manual workflow_dispatch with boolean full_build, but false/true dispatches have not run for code/test HEAD. The read-only API still shows #129 latest and no commit status for the code/test HEAD. The last UI pause observation was 2026-11-16; current UI state is not verified.
- mwan3 2.12.5 and ECM_CLASSIFIER_MARK_ENABLE=y are pinned/configured. Runtime fwmark/CONNMARK and actual NSS WAN-flow offload remain **NOT TESTED**.
- Runtime notifier, firewall4/mwan3, WAN failover, latency/loss/throughput, soak and recovery remain **NOT TESTED**.
- Keep the primary router on stock MiWiFi. CI images are not installable releases.



---

## 1. Цель проекта

Развивать отдельную сборку OpenWrt для **Xiaomi Mi Router AX3000T аппаратной ревизии RD03v2** с приоритетами:

1. Сохранить Qualcomm NSS/ECM аппаратное ускорение обычного маршрутизируемого и NAT-трафика.
2. Добавить два WAN: независимая работа каналов, failover и балансировка отдельных соединений.
3. Сохранить предсказуемое поведение DSA/AN8855 и штатных LAN/Wi-Fi функций.
4. Исследовать корректность ECM при изменении policy routing, fwmark и правил mwan3.
5. Отдельно оценить VPN/AmneziaWG, не приписывая VPN-трафику NSS-ускорение без измерений.
6. Сделать сборки воспроизводимыми: pinned upstream, pinned feeds, контроль патчей, проверка итогового образа и сохранение отчётов.

### Дополнение по ECM marks (15.11.2026)

Закреплённый NSS feed `qca-nss-ecm/Makefile` включает
`ECM_CLASSIFIER_MARK_ENABLE=y` для `qualcommax`; PREPARE_ONLY #78
подтвердил target `ipq50xx` и пакет `kmod-qca-nss-ecm`. Это означает, что
сборка запрашивает ECM mark classifier, но фактический NSS offload потоков с
mwan3 fwmark/CONNMARK должен быть измерен на роутере. Пакет
`iptables-mod-conntrack-extra` не предоставляет CLI `conntrack`;
`CONFIG_PACKAGE_conntrack` сейчас выключен. Для будущего выборочного
удаления conntrack entries потребуется отдельный пакет `conntrack` из
pinned `conntrack-tools` 1.4.8. См. `docs/dualwan.md`.

### 1.1. Неизменяемые ограничения

- Целевая плата — **RD03v2 / Qualcomm IPQ5018**. Не использовать образы или инструкции для MediaTek RD03/RD23.
- Аппаратная база проекта: IPQ5018, 256 МБ RAM, 128 МБ NAND, радиомодуль QCN6122 для 5 ГГц, коммутатор AN8855.
- Ветка проекта основана на mainline-derived NSS tree, Linux 6.18 и QSDK 14.0 ECM.
- Не менять одновременно базовый upstream, kernel, NSS feed, ECM, Wi-Fi и сетевую политику. Менять один логический слой за раз.
- Не считать успешный `make` доказательством работоспособности на железе.
- Не считать наличие пакета mwan3 доказательством работоспособного Dual-WAN.
- Не считать наличие NSS-пакетов доказательством, что конкретный поток действительно ускорен.

## 2. Текущая точка проекта

### 2.1. Репозиторий и ветки

- Fork: `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`
- Родительский проект: `ADCDS/openwrt-xiaomi-ax3000t-rd03v2`
- `main`: `14a07fbf317a00d2c592c7ffd262bcc3f4b6328c`
- Рабочая ветка: `work/rd03v2-dualwan-mwan3-baseline`
- Source implementation: `16193bfb29eecca103a370270458a779403ac619`; patch-envelope repair: `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`; functional test-harness commit: `0ca5b790cded21107f4ca72b987d3129790a9b18`; latest comment-only CI-trigger: `5b3328e23d36b2b1089e4b2342e0a5255578e022`. Patch blob: `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`; test harness blob: `dbb7859aed90d1b125de28801dd44d6826d3a2fe`. Code/test HEAD: `5b3328e23d36b2b1089e4b2342e0a5255578e022`; later branch changes are documentation-only.
- GitHub compare на 15.11.2026: общая точка с `main` — `14a07fbf317a00d2c592c7ffd262bcc3f4b6328c`, рабочая ветка `behind_by=0` (она содержит `main`). В ранней проверке было `ahead_by=52`, в более поздней — `ahead_by=54`; счётчик включает документационные commits и не означает столько же изменений прошивки. Перед PR/merge проверять live refs, не полагаться на сохранённое число. Merge/rebase из `main` на этой контрольной точке не требуется.

Сверять refs/SHA заново перед каждой работой: ветки и upstream со временем меняются. Не выполнять merge или rebase автоматически.

### 2.2. Что уже добавлено в рабочую ветку

Рабочая ветка содержит экспериментальную Dual-WAN package/config baseline и отдельный v2 ECM FIB-rule notifier port:

- `config/rd03v2.config`, `config/image-must-have.txt`, `config/kmods.config`;
- `feed-overlay/nss/qca-nss-ecm/patches/9001-...` и `9002-...`;
- `tools/test-ecm-fib-rule-patch.sh` — hash-verified QSDK apply и source/lifecycle checks;
- `tools/verify-v2.sh` и `tools/verify-artifacts.py`;
- `tools/test-watchdog.sh`, `tools/test-watchdog-init.py`, migration/package/pbuf/NFC tests;
- `tree-patches/0014-luci-app-nss-use-ipq50xx-runtime-dependency-only.patch`;
- `.github/workflows/rd03v2-validation.yml`;
- документация сборки, Dual-WAN, ECM, тест-план и handoff.

Patch 9002 **есть в active overlay**. Earlier revision passed pinned-source/full-feed-series preflight and was compiled in CI #124; current gate-first revision is committed but has not yet passed exact source apply or compilation. Runtime correctness and NSS-safe failover **не доказаны на железе**. Ветка не содержит готовой аппаратно проверенной конфигурации второго WAN. Полный перечень работ — [OPEN_ITEMS_REGISTER_RU.md](OPEN_ITEMS_REGISTER_RU.md).

### 2.3. Исторические результаты CI #124–#129 (16.11.2026)

- CI #124: Static **PASS**, PREPARE_ONLY **PASS**, raw QSDK source apply, полная очередь 32 ECM feed patches, lifecycle и atomic-callback guards **PASS**.
- Полная сборка #124 создала sysupgrade и initramfs-factory images; `qca-nss-ecm` скомпилирован, `kmod-qca-nss-ecm` включён в rootfs, marker FIB notifier найден в `ecm.ko`; rootfs — 223 packages.
- Финальный `verify-v2` #124 — **FAIL**: watchdog suite 20 PASS / 26 FAIL и два ECM source fingerprints false-negative после `CONFIG_AUTOREMOVE=y`.
- CI #125/#126 провалили только `git diff --check` из-за лишней пустой строки в handoff; PREPARE_ONLY/full-build были skipped. `e31ca88` устранил trailing blank line.
- CI #127 на `faa82e24`: Static checks **PASS**, PREPARE_ONLY и exact QSDK/full ECM queue preflight **PASS**. Full-build job запустил `./build.sh`, но runner shutdown прервал процесс с кодом 143; compile и final verify не получены.
- CI #128/#129 cancelled before jobs. There is no later run or commit status for code/test HEAD `5b3328e23d36b2b1089e4b2342e0a5255578e022`. The active patch blob is `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`; the current test harness blob is `dbb7859aed90d1b125de28801dd44d6826d3a2fe`. Exact apply/compile/full verify after these revisions remain NOT TESTED.
- Исправления watchdog (`f372d519`, `0d2aeadb`) и AUTOREMOVE verifier (`e7846a1`, `49d3579`) не получили завершённого full-build и final-verifier подтверждения на последующих source/test ревизиях.
- Pinned kernel: Linux **6.18.55**. Generic config fragment включает `CONFIG_FIB_RULES`, `CONFIG_IP_ADVANCED_ROUTER` и `CONFIG_IP_MULTIPLE_TABLES`; проектная конфигурация включает `CONFIG_IPV6_MULTIPLE_TABLES`.
- PREPARE_ONLY выбирает `mwan3`, `luci-app-mwan3`, `kmod-qca-nss-ecm`, NSS DWMAC и nft-backed iptables packages.
- Три unrelated Kconfig diagnostics остаются для Qt5 GUI, fwknopd/LuCI fwknopd и squeezelite-custom; пакеты не выбраны. Цикл Kconfig выбранного NSS отсутствует после patch 0014.
- Runtime ECM load/unload, FIB churn, firewall4/mwan3 runtime, WAN failover, conntrack, NSS counters/throughput и аппаратные Dual-WAN/NSS тесты остаются **NOT TESTED**.

### 2.4. Текущие pinned source revisions

Из документации рабочей ветки:

- OpenWrt/NSS tree: `c36db6321c11595dc45a160cdab36b5c2d787744`
- NSS feed: `57c0fa18f847f6cb23992ff3493c6a9131246f4c`
- `qca-nss-ecm`: `7894b769eeb64f1c44fde547a107a8b866997590`
- ECM source line: QSDK 14.0, 2026-09-06
- Kernel line: Linux 6.18.55
- mwan3 package pin: 2.12.5 (проверять фактический feed lock и Makefile при обновлении)

Эти pins — исходная точка, не рекомендация автоматически обновить их до последних версий. Любой bump требует повторной проверки патчей, API, зависимостей и сборки.

## 3. Архитектура сети и целевые режимы

### 3.1. WAN

Провайдеры в пользовательской схеме:

- WAN1: EVPANET, статическая IPv4-конфигурация.
- WAN2: EVNAT, DHCP-конфигурация.

Не помещать реальные публичные IP, логины, пароли, ключи VPN, серийные номера и конфигурационные секреты в публичные файлы репозитория. В документации использовать плейсхолдеры. Реальные параметры хранить локально в защищённом файле/менеджере секретов.

До создания mwan3 определить на самом устройстве:
- физический порт AN8855;
- DSA netdev для каждого порта;
- CPU conduit и VLAN;
- фактическое имя netifd logical interface;
- gateway, DNS, MTU, IPv4/IPv6 и тип инкапсуляции.

Не предполагать, что второй интерфейс автоматически называется `wanb`. Не копировать port mapping с MediaTek AX3000T.

### 3.2. Что именно даёт mwan3

mwan3 выполняет policy routing, распределение **отдельных соединений** и failover. Он не объединяет два WAN в один более быстрый TCP-поток.

Ожидаемые режимы:
1. Один WAN — базовая проверка.
2. Failover: WAN1 основной, WAN2 резервный.
3. Обратный failover: WAN2 основной, WAN1 резервный.
4. Взвешенная балансировка независимых потоков после успешного failover.
5. Специальная политика для игрового трафика, если критерии выбора WAN и способ определения адресов сервера надёжно установлены.

Для Warface приоритет — стабильность RTT, jitter и потерь, а не переключение на каждый единичный скачок ping. Нужны hysteresis, hold-down interval и тесты против flapping. Обычный mwan3 не является интеллектуальным контроллером выбора WAN по минимальному RTT.

### 3.3. NSS и VPN

Разделять минимум три класса трафика:

- обычный NAT/routed traffic без VPN;
- трафик, ускоренный ECM/NSS;
- трафик через AmneziaWG/WireGuard.

На этой платформе нельзя обещать ECM-ускорение VPN-туннеля без конкретного подтверждения. VPN может идти через CPU path, при этом обычный NAT вне туннеля продолжает использовать NSS. Измерять эти режимы отдельно.

## 4. Критический вопрос: ECM и policy routing

### 4.1. Известное поведение v1.x

В v1.x ADCDS исправлял проблему ECM/mwan3 в PR #40; исправление вошло в v1.14 как ECM patch 0030. Оно реагировало на события `FIB_EVENT_RULE_ADD` и `FIB_EVENT_RULE_DEL`, затем инвалидировало ускоренные соединения соответствующего семейства адресов через отложенную workqueue.

Документированные испытания v1.x включали воспроизведение routed IPv6 stall, восстановление после notifier, 800 изменений policy rules за 4,4 секунды без kernel warnings и длительный тест около 16 часов с тремя рестартами mwan3.

Это свидетельство относится к конкретной комбинации v1.x kernel/ECM. Оно **не доказывает** корректность того же патча в v2.

### 4.2. Исторические результаты v2 и актуальный статус

В active feed-overlay присутствует отдельный RD03v2/QSDK 14.0 ECM patch 9002 для FIB policy-rule ADD/DEL. Raw apply, полная pinned feed queue и C-компиляция в CI #123/#124 относятся к более ранней реализации patch. Текущая реализация находится в patch 9002 (implementation commit `16193bfb29eecca103a370270458a779403ac619`, envelope repair `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`, blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`); актуальный regression harness — blob `dbb7859aed90d1b125de28801dd44d6826d3a2fe` (functional commit `0ca5b790cded21107f4ca72b987d3129790a9b18`, comment-only CI-trigger `5b3328e23d36b2b1089e4b2342e0a5255578e022`). Эти изменения ещё не получили повторный exact-source apply, compile и final verifier.

Final `verify-v2.sh` в #124 завершился **FAIL** по трём проверкам: watchdog test harness и source fingerprints 9001/9002 после `CONFIG_AUTOREMOVE=y`. Watchdog fixes (`f372d519`, `0d2aeadb`) и AUTOREMOVE verifier fixes (`e7846a1`, `49d3579`) коммичены, но не получили завершённого full CI с `verify-v2` PASS. CI #127 прошёл Static и PREPARE_ONLY, но full-build был прерван runner shutdown (exit 143). Поэтому повторная компиляция и final verifier после этих исправлений не подтверждены.

При применении patch 9002 в compile log CI #124 GNU patch сообщил fuzz 1–2 на нескольких hunks, включая ecm_exit insertion. Source lifecycle guard подтвердил placement notifier stop перед conntrack/frontend teardown, но patch нельзя называть fuzz-free. Runtime обязательные gates:

1. Завершить full CI и final `verify-v2` на актуальном code/test SHA.
2. Проверить watchdog suite в host и target BusyBox либо обосновать, почему target suite не является release gate.
3. Проверить runtime registration/unregistration, initial FIB replay, module load/unload, FIB churn и teardown stress на втором RD03v2.
4. Проверить mwan3/firewall4, оба WAN, tracker `disconnected`, реальный `ifdown`/cable pull, IPv4/IPv6, conntrack marks и NSS/ECM counters.
5. Измерить slow-path/re-acceleration, CPU, throughput, latency, packet loss и долгосрочную стабильность.

Patch 9002 использует atomic notifier callback только для установки pending bits и постановки work; worker берёт per-net RTNL для согласованного снимка событий, затем отпускает его до `synchronize_net()` и обхода ECM DB. При teardown unregister notifier дожидается RCU readers, после чего `cancel_work_sync()` дренирует worker. Это подтверждено source-level review и CI preflight, но не runtime на плате.

См. [реестр незакрытых задач](OPEN_ITEMS_REGISTER_RU.md), [план испытаний](TEST_PLAN_RU.md), [Dual-WAN details](dualwan.md) и [CI build record](CI_BUILD.md).

### 4.3. Что notifier не обещает

- Не гарантирует сохранение существующих IPv4 NAT-сессий при миграции на другой WAN.
- Не делает NAT66 автоматически ECM-offloaded.
- Может инвалидировать ускоренные потоки семейства адресов и вызвать временный переход на slow path/re-acceleration.
- Не заменяет корректную conntrack/NAT/policy routing конфигурацию.

Критерий успеха failover — новые соединения идут через рабочий WAN, а поведение существующих соединений задокументировано отдельно.

## 5. Сборочная среда и воспроизводимость

### 5.1. Требования

Собирать на Linux-хосте с достаточным объёмом RAM и диска. Скрипт `finish-build-v2.sh` по умолчанию требует не менее 4 GiB `MemAvailable` и использует lock, чтобы не запускать параллельно тяжёлые сборки. Практически предпочтительнее больше RAM и свободного SSD-пространства.

В рабочем пространстве рядом с репозиторием используются:
- `mirrors/`
- `keys/v2/`
- `dl-v2/`
- `v2-tmp/`
- `v2-validation/`

Не хранить приватный ключ в Git. Требуется локальная пара:
- `keys/v2/private-key.pem`, права строго `0600`;
- `keys/v2/public-key.pem`, совпадающий с публичным ключом `keys/public-key.pem` в репозитории.

Не отправлять private key в чат, issue, логи CI или публичный artifact.

### 5.2. Подготовка дерева без компиляции

Из корня репозитория:

```sh
TAG=DEV-rd03v2-baseline PREPARE_ONLY=1 JOBS=2 ./build.sh
```

Для `PREPARE_ONLY=1` приватный ключ подписи не требуется: скрипт проверяет pinned upstream, зеркала, patches, feeds, overlay и конфигурацию, выполняет `make defconfig`, сохраняет `.config` и `diffconfig.txt`, затем останавливается до package/image compilation. В этом режиме ключ не валидируется и не копируется в build tree.

Для локального продолжения подготовленного дерева ключ должен находиться в защищённом workspace-каталоге `keys/v2/` (или в каталоге `V2_KEY_DIR`): `private-key.pem` с правами `0600` и соответствующий `public-key.pem`. Публичный ключ должен совпадать с `keys/public-key.pem` в репозитории. `finish-build-v2.sh` вызывает отдельный `tools/install-v2-signing-key.sh`, который проверяет пару и устанавливает её в подготовленное дерево только если ключи там отсутствуют. Если в дереве есть неполная или несовпадающая пара, helper останавливается, ничего не перезаписывая. Локальный тест подтвердил установку, повторный идемпотентный запуск и отказ при mismatch/partial pair. Приватный ключ не добавлять в Git и не загружать в CI artifacts.

`build.sh` ожидает чистое имя дерева (по умолчанию `openwrt-v2`) и завершится, если такое дерево уже существует. Не запускай его повторно после `PREPARE_ONLY=1` на том же пути и не удаляй существующее дерево автоматически: оно может содержать результаты предыдущей подготовки/сборки.

### 5.3. Полная сборка из подготовленного дерева

После успешного `PREPARE_ONLY=1` и проверки логов продолжить то же дерево:

```sh
JOBS=2 ./tools/finish-build-v2.sh ./openwrt-v2
```

### 5.4. Полная сборка с нуля

Использовать только если целевого дерева ещё нет:

```sh
TAG=DEV-rd03v2-baseline JOBS=2 ./build.sh
```

Фактический путь к дереву зависит от `RD03V2_WS` и `TREE`; сначала сверить путь. Не запускать второй тяжёлый build одновременно.

Скрипт выполняет download, полную сборку, индексацию пакетов, создание Wi-Fi initramfs installer pair и `tools/verify-v2.sh --tree`. Смотреть:
- `feeds-update.log`
- `feeds-install.log`
- `defconfig.log`
- `tmp/.config-package.in` — generated Kconfig dependency graph (available in the updated CI preparation artifact)
- `download.log`
- `build.log`
- `wifi-initramfs.log`
- `verify-v2.sh` PASS/FAIL вывод

### 5.4. Обязательные артефакты

Для каждой сборки сохранять:
- git HEAD и branch;
- `upstream.lock`, `feeds.lock`;
- `.config` и `diffconfig.txt`;
- полный build log;
- verify log;
- manifest пакетов;
- SHA-256 всех образов и пакетов;
- версию ядра, NSS/ECM, mwan3;
- краткое описание изменений и known issues.

Сборка считается **успешной компиляцией** только при exit code 0 всех обязательных стадий и успешном завершении `verify-v2.sh`. Это ещё не означает, что она прошла hardware validation.

## 6. Ворота проверки перед прошивкой

### Gate A — статическая проверка

- Проверить `git status`, diff и историю.
- Проверить, что upstream и feeds pinned.
- Убедиться, что выбран ровно один target device.
- Убедиться в наличии ожидаемых NSS/ath11k 256M профилей.
- Проверить `CONFIG_FIB_RULES=y`, `CONFIG_IP_MULTIPLE_TABLES=y`, `CONFIG_IPV6=y`, `CONFIG_IPV6_MULTIPLE_TABLES=y`.
- Проверить `iptables-nft`, `ip6tables-nft`, `xtables-nft`, `ipset` и требуемые extensions.
- Убедиться, что нет случайного legacy backend.
- Проверить manifest именно из rootfs итогового sysupgrade image, а не только staging directory.

### Gate B — компиляция

- `make defconfig` завершился успешно.
- `make download` завершился успешно.
- Полная сборка завершилась успешно.
- `verify-v2.sh --tree` завершился с нулём FAIL.
- Созданы ожидаемые sysupgrade и installer artifacts.
- SHA-256 записаны и проверены.

### Gate C — тест на запасном устройстве

Не использовать основной роутер первым испытательным образцом. До прошивки подготовить:
- проверенный recovery/revert сценарий именно для RD03v2;
- стабильное питание и Ethernet-доступ;
- резервную копию конфигурации;
- подтверждённый файл образа и его SHA-256;
- план возврата на известную рабочую версию.

Не применять команды принудительной прошивки только потому, что обычная проверка отказала. Сначала установить причину отказа и сверить release notes.

### Gate D — сетевые испытания

Сначала один WAN, затем второй WAN, затем два WAN. Не добавлять ECM patch и балансировку одновременно.

## 7. Порядок аппаратных тестов

### 7.1. Инвентаризация устройства

Сохранять выводы:

```sh
ubus call system board
cat /etc/rd03v2-release
uname -a
cat /proc/meminfo
ip -br link
ip -br addr
bridge link
bridge vlan show
ip -4 route show table all
ip -6 route show table all
dmesg
logread
```

Дополнительно снять `ethtool -S <interface>`, если драйвер поддерживает вывод счётчиков.

### 7.2. Один WAN за раз

Для WAN1 и WAN2 отдельно:
- DHCP/static/PPPoE параметры;
- gateway и DNS;
- MTU и fragmentation/PMTU;
- доступность IPv4 и IPv6;
- RTT, jitter, packet loss;
- download/upload;
- CPU usage;
- NSS/ECM counters;
- conntrack counters;
- длительный тест и повторные переподключения.

Сравнить NSS on/off, если в конкретной версии предусмотрен поддерживаемый переключатель. Не менять NSS режим без фиксации reboot requirement и текущего состояния.

### 7.3. Firewall4 + mwan3

При включённом firewall4 и обоих WAN проверить:

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

Ожидание: iptables/ip6tables сообщают backend `nf_tables`; цепочки mwan3 и sets существуют; правила fwmark направляют трафик в правильные таблицы; firewall4 ruleset остаётся целым после mwan3 restart и ifdown/ifup.

Это runtime-критерии. Одной проверки Kconfig недостаточно.

### 7.4. Failover матрица

Проверить отдельно:
1. WAN1 primary, WAN2 backup; отключить WAN1.
2. Восстановить WAN1; измерить возврат на primary.
3. WAN2 primary, WAN1 backup; отключить WAN2.
4. DHCP renew / PPPoE reconnect.
5. Потеря gateway при физически поднятом Ethernet.
6. Кратковременная потеря пакетов и восстановление.
7. Несколько параллельных TCP/UDP flows.
8. Долгая нагрузка при переключении.

Фиксировать время обнаружения отказа, время переключения, потерю пакетов, маршрут новых соединений и судьбу уже существующих соединений. Не считать разрыв старой NAT-сессии доказательством неисправности, если новые сессии успешно пошли через резервный WAN.

### 7.5. ECM / policy rule churn

Сравнить stock ECM и кандидатный ECM patch:
- IPv4 NAT;
- routed IPv4;
- routed IPv6 при наличии реального IPv6 у обоих ISP;
- PPPoE;
- DHCP/static WAN;
- разные порядки добавления routes и rules;
- многократный `mwan3 restart`;
- физический pull кабеля;
- повторное восстановление WAN.

Собирать throughput, CPU, ECM counters, route/rule snapshots, kernel warnings, время восстановления. NAT66 тестировать отдельно от routed IPv6.

### 7.6. Wi-Fi и память

Проверять 2.4 и 5 ГГц отдельно и одновременно:
- NSS Wi-Fi offload;
- host Wi-Fi mode только как отдельный диагностический режим;
- слабый RSSI и повторные передачи;
- fragmented frames, если есть безопасный тестовый стенд;
- параллельный wired NAT traffic;
- длительный soak;
- доступную RAM, slab, OOM, kernel log и NSS queue drops.

Не делать вывод о стабильности по короткому speedtest. Устройство имеет 256 МБ RAM; любой дополнительный daemon и сборщик телеметрии должен оцениваться по памяти и CPU.

### 7.7. AmneziaWG

AWG kernel module и tools должны соответствовать точному kernel build и поставляться из подписанного репозитория проекта. README указывает, что AWG не входит в базовый образ.

Проверить отдельно:
- handshake и rekey;
- маршруты и DNS;
- policy routing;
- MTU;
- throughput и CPU;
- reconnect после WAN failover;
- отсутствие ложных заявлений об NSS offload VPN traffic.

## 8. Обновление и сохранение настроек

Всегда сверять release notes именно выбранной версии и hardware target RD03v2.

### 8.1. Установка из штатной MiWiFi

Согласно README проекта, переход со штатной прошивки выполняется штатным installer workflow проекта `xiaomi-openwrt-install`, который проверяет плату/NAND и записывает подходящий образ. Не использовать случайный sysupgrade образ из другой ревизии и не считать Web UI штатной MiWiFi универсальным способом установки сторонней прошивки.

Официальная инструкция проекта:
- [README: Installation](../README.md)
- [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install)

### 8.2. Обновление уже установленной v2

README проекта описывает in-place `sysupgrade` с сохранением настроек для установленной v2. Но:
- настройки сохраняются, дополнительные пакеты — нет;
- после обновления проверить конфигурацию, firewall, WAN, Wi-Fi и NSS;
- не прерывать питание во время записи;
- v2.0.0–v2.1.2 имеют отдельную оговорку: README указывает на однократный `sysupgrade -F` для обхода ошибочного отказа проверки. Использовать это только при точном совпадении исходной версии, target и release notes; не превращать `-F` в обычную команду обновления.

До обновления сохранить backup через LuCI или поддерживаемую команду `sysupgrade -b`, скопировать файл за пределы роутера и сохранить список установленных пакетов и ключевые конфиги. Проверить backup до того, как он понадобится.

### 8.3. После обновления

Проверить:
- `ubus call system board`;
- `cat /etc/rd03v2-release`;
- `uname -a`;
- `nss-status`, если доступен;
- WAN и DNS;
- Wi-Fi 2.4/5 GHz;
- firewall4 и mwan3;
- NSS/ECM counters;
- свободную RAM;
- системный журнал.

Пакеты, добавленные отдельно, могут потребовать повторной установки. Kernel modules должны соответствовать именно установленному kernel/package repository.

## 9. Git workflow и правила изменений

### 9.1. Ветвление

- `main` — базовая ветка форка (на контрольной точке `14a07fb`).
- `work/rd03v2-dualwan-mwan3-baseline` — рабочая экспериментальная ветка. Не хранить число ahead/behind как постоянную характеристику: сравнивать refs с `main` непосредственно перед PR/merge. Текущая branch HEAD и code/test baseline различаются, поскольку последующие коммиты меняли документацию; сверять оба SHA отдельно.
- Для отдельного ECM port, нового Wi-Fi патча или upstream bump создавать отдельные feature branches от актуальной рабочей базы.
- Не коммитить эксперимент прямо в main.
- Сначала review diff, затем commit, затем сборка и тесты, затем PR/merge.

### 9.2. Обновление upstream

Перед bump:
1. Зафиксировать текущий upstream SHA, NSS feed SHA и feed locks.
2. Посмотреть changelog, commit range и изменённые файлы.
3. Проверить каждый локальный patch на конфликт/устаревший контекст.
4. Проверить kernel config symbols и package dependency changes.
5. Проверить Wi-Fi BDF/firmware и NSS/ECM совместимость.
6. Выполнить подготовку, компиляцию и verify.
7. Только потом проводить аппаратные тесты.

Не делать массовый bump всех feeds «до последнего». Воспроизводимость важнее формально самой новой версии.

### 9.3. Обязательные данные коммита

Каждый функциональный commit должен объяснять:
- какую проблему решает;
- какие файлы меняет;
- почему решение совместимо с RD03v2;
- какие проверки выполнены;
- какие тесты не выполнены;
- известные риски;
- способ отката.

## 10. Матрица приёмки релиза

Релиз не считается готовым, пока нет результатов по следующим пунктам:

| Область | Минимальный критерий |
|---|---|
| Hardware identity | Подтверждён RD03v2 |
| Provenance | Зафиксированы upstream/feed SHAs |
| Build | Полная сборка завершена без ошибок |
| Image verification | `verify-v2.sh` без FAIL |
| Boot | Устройство загрузилось, нет критических kernel errors |
| Ethernet/DSA | Все нужные порты определены и работают |
| Wi-Fi | 2.4/5 GHz, AP/client и длительная нагрузка |
| NSS/ECM | Подтверждены counters и фактическое ускорение |
| WAN1 | Отдельный baseline |
| WAN2 | Отдельный baseline |
| mwan3 | Chains, sets, fwmark и routing tables работают |
| Failover | Оба направления проверены |
| ECM rule changes | Нет зависших потоков/необъяснимых stalls |
| IPv6 | Только при реальном рабочем IPv6, отдельно от IPv4 |
| VPN | Отдельные измерения CPU/throughput/reconnect |
| Stability | Длительная нагрузка, RAM, kernel log |
| Recovery | Проверен путь восстановления |
| Artifacts | Manifest, logs, SHA-256, config и release notes |

В отчёте указывать один из статусов:
- **PASS** — проверено и пройдено;
- **FAIL** — проверено и не пройдено;
- **NOT TESTED** — не проверялось;
- **NOT APPLICABLE** — не относится к данной конфигурации;
- **INCONCLUSIVE** — данных недостаточно.

Нельзя заменять NOT TESTED на PASS.

## 11. Приоритетный план ближайших работ

Подробный список задач, зависимостей и критериев закрытия ведётся централизованно в
[реестре незакрытых задач](OPEN_ITEMS_REGISTER_RU.md). Не поддерживать параллельные
копии длинного плана в этом мануале.

Текущая очередь:

1. **P0 — CI:** получить completed full CI на актуальном code/test SHA, подтвердить watchdog suite, AUTOREMOVE verifier и final `verify-v2.sh`. #127 Static/PREPARE_ONLY PASS не заменяет полный build.
2. **P0 — безопасность стенда:** до любых записей во flash подтвердить второй RD03v2, backup, проводной доступ и проверенный recovery path. Основной роутер остаётся на stock MiWiFi.
3. **P1 — ECM/NSS:** runtime notifier register/unregister, module lifecycle, initial FIB replay, FIB churn, lockdep/teardown stress и counters.
4. **P1 — Dual-WAN:** firewall4/mwan3 runtime, WAN1/WAN2 по отдельности, tracker `disconnected` отдельно от netifd `ifdown`, failover в обе стороны, conntrack marks и IPv4/IPv6.
5. **P1 — измерения:** single-flow и multi-flow throughput, NSS on/off, CPU/RAM, RTT/jitter/loss и чувствительный к latency трафик.
6. **P2 — release:** постоянная подпись, реальный package repository, image hashes/manifests, recovery-tested install/rollback и release notes.

Не закрывать задачу без указанного в реестре доказательства.
## 12. Сбор диагностического отчёта

Для каждого тестового прогона создать отдельную папку, например:

```text
validation/
  YYYY-MM-DD_<build-tag>/
    metadata.txt
    board.txt
    kernel.txt
    memory.txt
    links.txt
    addresses.txt
    routes-v4.txt
    routes-v6.txt
    bridge.txt
    nft-ruleset.txt
    mwan3-status.txt
    nss-status.txt
    dmesg.txt
    logread.txt
    throughput.csv
    ping-wan1.csv
    ping-wan2.csv
    sha256sums.txt
    verdict.md
```

Перед публикацией удалять пароли, ключи, публичные адреса, MAC-адреса и иные чувствительные данные. Для внутреннего анализа сохранять полную копию в закрытом хранилище пользователя.

## 13. Первичные источники

- [Твой RD03v2 fork](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2)
- [Рабочая ветка Dual-WAN](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/tree/work/rd03v2-dualwan-mwan3-baseline)
- [Upstream ADCDS](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2)
- [Upstream releases](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/releases)
- [v2 validation](../VALIDATION.md)
- [План испытаний и приёмки](TEST_PLAN_RU.md)
- [Состояние и устройство CI-сборки](CI_BUILD.md)
- [Dual-WAN baseline](dualwan.md)
- [ECM policy-routing port plan](ecm-policy-routing-port.md)
- [OpenWrt mwan3 documentation](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3)
- [Xiaomi installer](https://github.com/ADCDS/xiaomi-openwrt-install)

---

## 14. Правила для дальнейшей работы с ИИ/Codex

Каждую техническую задачу выполнять по следующему шаблону:

1. **Сначала прочитать** README, этот MANUAL, VALIDATION.md, upstream.lock, feeds.lock и связанные документы.
2. **Установить точное состояние** репозитория, ветки, commit SHA и незакоммиченных изменений.
3. **Сформулировать гипотезу** и критерий, который её опровергнет.
4. **Найти первоисточник**: код, Makefile, commit, issue или техническую документацию.
5. **Не переносить выводы** с другой аппаратной ревизии, kernel line или ECM/NSS версии.
6. **Внести минимальное изменение** в отдельной ветке.
7. **Провести self-review**: проверить собственные команды, diff, зависимости и побочные эффекты.
8. **Запустить доступные проверки** и сохранить их полный результат.
9. **Честно отметить ограничения**: compile-tested, image-verified, device-tested или NOT TESTED.
10. **Не прошивать и не публиковать** без прохождения соответствующих ворот приёмки.

Формат ответа по каждой задаче:
- Цель и гипотеза.
- Что проверено в исходниках.
- Что изменено (commit SHA и список файлов).
- Какие команды реально выполнены.
- Результаты PASS/FAIL.
- Что осталось NOT TESTED.
- Риски и план отката.
- Следующий минимальный технический шаг.

**Главный принцип проекта:** сначала доказать корректность, затем оптимизировать скорость. Для RD03v2 приоритет — стабильный NSS и предсказуемый failover, а не максимальное число патчей или пакетов.
