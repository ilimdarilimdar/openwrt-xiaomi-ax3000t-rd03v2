# Передача проекта следующему ИИ-агенту: Xiaomi AX3000T RD03v2

> **Назначение файла:** единая точка входа и рабочая опорная запись для любого следующего ИИ-агента, который продолжит разработку этой прошивки. Сначала прочитать этот файл, затем сверить живое состояние GitHub. Не считать сведения ниже неизменными: SHA, очередь CI и состояние сборки необходимо обновлять перед каждым действием.

**Последняя сверка исходного состояния:** 2026-11-15, текущая сессия
**Последний source-code commit:** `e80f964efb78331be0c5c8c26c29a724f0c668cb` (переведён FIB worker на per-net RTNL lock)
**Текущий branch HEAD на момент записи:** `70f92cc24098933a252c803403368534e97ec587` (исправлена кавычка Bash в preflight test); перед изменениями всегда получать актуальный HEAD из GitHub.
## Актуальная контрольная точка — 2026-11-15

- CI #77, source `ac4ee43`: Static PASS и PREPARE_ONLY PASS; pinned QSDK archive hash
  и применение 9002 после 31 feed-патча подтверждены. Full build завершился
  **FAIL** в `package/feeds/nss/qca-nss-ecm`; package compiler log не попал в
  старый artifact, поэтому точная причина пока не установлена.
- CI #78, source `3614994`: Static PASS, PREPARE_ONLY PASS и обновлённый ECM
  preflight PASS. Preflight подтвердил применение 9002 после всех 31 feed-патча
  и все проверки init/unwind/normal-exit. Full build job ещё выполняется на
  последней live-проверке; результат компиляции и `verify-v2` не подтверждён.
- Source commit `e80f964` меняет worker lock с общего `rtnl_lock()` на
  `rtnl_net_lock(&init_net)` / `rtnl_net_unlock(&init_net)`, соответствуя
  per-net RTNL primitive Linux 6.18 FIB rule update. Это устраняет условную
  рассинхронизацию при `CONFIG_DEBUG_NET_SMALL_RTNL`.
- В `tools/test-ecm-fib-rule-patch.sh` обновлены assertions на per-net lock.
  Дополнительный commit `70f92cc` исправляет кавычки Bash в grep assertion.
  Проверка этих последних изменений ожидает CI #82.
- CI #82, run `43715272931`, commit `70f92cc`: PENDING на последнем
  live-check. Он содержит обновлённый worker, test script и исправленный
  artifact glob. CI #79–#81 были отменены более новыми push.
- Workflow artifact glob исправлен на `openwrt-v2/logs/package/feeds/nss/**`,
  чтобы следующая полная сборка сохраняла реальные per-package компиляторные логи.
- Не считать прошивку готовой. Требуются: успешная компиляция ECM, marker в
  `ecm.ko`, `verify-v2.sh`, затем контролируемые испытания на втором RD03v2.
  Основной роутер остаётся на штатной прошивке.

Исторические записи ниже сохранены как журнал; при расхождении использовать
эту контрольную точку и актуальное состояние GitHub.

**Репозиторий:** `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`
**Рабочая ветка:** `work/rd03v2-dualwan-mwan3-baseline`
**Baseline source/config до эксперимента ECM FIB notifier:** `f5e828fa1cceb123fee81a1bafe5c9a71d0a81fb`.
**Текущий source state:** firmware source HEAD `e80f964efb78331be0c5c8c26c29a724f0c668cb` включает candidate patch 9002, lifecycle shutdown hook и per-net RTNL barrier. Для более ранней lifecycle revision CI #78 подтвердил source preflight, но full build ещё выполняется. Новый per-net lock и обновлённый test script ждут CI #82. Ни одна ревизия 9002 пока не имеет подтверждённой успешной компиляции и hardware tests.
**Последний commit изменения CI workflow:** `472ed0ce1b2f2fa68c78f362edfc5b5f388bc7c7`.
**История изменений:** после baseline добавлены source patch 9002 и lifecycle изменения в commit `3614994`; отдельные commits изменяли CI workflow и документацию. Не считать старую формулировку ниже, что после baseline были только docs/CI, актуальной.

**Последний статус на момент аудита:** активная разработка; базовая конфигурация и автоматические проверки есть, полная сборка Dual-WAN-ветки и её аппаратная пригодность не подтверждены.

> Перед любым действием получить живой HEAD. Последующие обновления этого handoff тоже создают documentation-only commit и двигают branch HEAD; не считать такой сдвиг изменением firmware code.

---

### ECM worker lock alignment — 2026-11-15

В patch 9002 worker использует `rtnl_net_lock(&init_net)` /
`rtnl_net_unlock(&init_net)`, совпадая с per-net RTNL primitive в Linux 6.18
FIB rule operations. Не использовать только общий `rtnl_lock()`: при
`CONFIG_DEBUG_NET_SMALL_RTNL` он может не сериализовать worker с изменением
rules в `init_net`. Static preflight теперь должен проверять именно net-scoped
lock и его release до ECM DB walk. Это source-level guard, не замена compile и
hardware stress tests.

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

Патч 0014 — **исправление-гипотеза до проверки нового PREPARE_ONLY**. Нельзя утверждать, что Kconfig-цикл устранён, пока не проверены свежие `defconfig.log`, `.config` и `tmp/.config-package.in` на последнем HEAD.

## 5. Состояние CI при последней подтверждённой проверке

Проверка GitHub Actions обновлена 2026-11-15 около 08:25 UTC.

| Workflow | Commit | Последний известный результат |
|---|---|---|
| #15 | `c5a64af9a23996401eb22c2a275023c419bbe547` | Static PASS; PREPARE_ONLY PASS; artifact inspected |
| #16 | `5bcad81cfe911b91f4ac928e53f424e1580ddfd7` | Static PASS; full build step IN PROGRESS |
| #43–#56 | промежуточные commits | CANCELLED последующими push до завершения соответствующих проверок |
| #57 | `6878d6d16ab9858a136a6c4d224e0b53d07942cc` | PENDING; jobs ещё не начались; содержит актуальный 9002 и проверку порядка pending-bit snapshot |

Подробности:

- Артефакт #15: ID `14150612353`, `rd03v2-prepare-c5a64af9a23996401eb22c2a275023c419bbe547`. Он подтвердил прежний NSS Kconfig цикл `luci-app-nss -> kmod-qca-nss-drv -> kmod-qca-dsa-nss -> nss-tools-dwmac -> nss-tools -> luci-app-nss`. Коммит #15 предшествует патчу 0014, поэтому не проверяет устранение цикла.
- В #16 checkout, runner resource check и временная CI-подпись прошли. `Build and run verify-v2` продолжает выполняться; лог/артефакты не доступны до завершения. Тайм-аут — 360 минут. Не отменять этот запуск лишь из-за длительности.
- #43–#56 были отменены последующими push до завершения соответствующих проверок. `cancelled` здесь означает superseded/отменённый queued run, а не доказанную ошибку исходников или сборки.
- #57 на commit `6878d6d` находится в `pending`; GitHub ещё не вернул jobs. Run включает candidate patch 9002, pinned-source preflight, проверку порядка pending-bit snapshot под RTNL и marker check в `verify-v2`.
- Commit `6878d6d` исправил только escaping `\n` в двух `DEBUG_TRACE` строках IPv4/IPv6 worker; diff сверён. Сама логика RTNL snapshot и pending-bit requeue не менялась. Run #57 остаётся в очереди за #16.
- #16 остаётся `in_progress` на более раннем commit `5bcad81`; его full-build step не завершился. Этот run не содержит candidate patch 9002 и не подтверждает его сборку.
- Patch 0014 ручным `git apply --check` подтверждён против точного upstream Makefile с совпадающим blob SHA; Kconfig effect всё ещё требует свежего PREPARE_ONLY.
- Candidate ECM patch 9002 использует v2 `*_stop_temp()` counters, атомарный FIB callback → workqueue → per-family connection defunct и RTNL publication barrier. Worker снимает IPv4/IPv6 pending bits под RTNL, затем отпускает RTNL и только после этого запускает ECM DB walk. Это не даёт новому rule event потеряться в уже выполняющемся старом проходе.
- Teardown снимает FIB notifier и вызывает `cancel_work_sync()` до DB termination. Registration failure остаётся non-fatal и не перезаписывает `ret` инициализации route notifier.
- PREPARE_ONLY запускает `tools/test-ecm-fib-rule-patch.sh`: скачивает QSDK archive по полям pinned feed Makefile, сверяет PKG_HASH, `git apply --check`/apply и проверяет callback, ADD/DEL, IPv4/IPv6, RTNL barrier и teardown.
- `verify-v2.sh` проверяет runtime registration marker внутри `ecm.ko`, извлечённого из sysupgrade rootfs, а ECM patch fingerprints ищутся по всему source tree, не только в `frontends`.
- Patch 9002 пока **NOT APPLY-VALIDATED, NOT COMPILED, NOT HARDWARE-TESTED**. Не выдавать его за готовую функцию до успешного preflight, сборки и аппаратных испытаний.
- CI full-build использует disposable key и `example.invalid`, поэтому не является пользовательским образом. Аппаратной валидации Dual-WAN/NSS нет.

Ссылки:

- [Actions workflow](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/workflows/rd03v2-validation.yml)
- [Run #15 — PREPARE_ONLY artifact](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686096014)
- [Run #16 — full build](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686188656)
- [Run #57 — latest ECM pending-bit snapshot validation](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43693127906)

**Первое действие следующего агента:** обновить статусы #16 и #57. У #16 проверить итог full build/verify-v2; его исходники старше candidate 9002. Для #57 проверить Static, PREPARE_ONLY и ECM archive preflight, затем открыть artifact и проверить, исчез ли NSS Kconfig cycle после patch 0014. После успешной подготовки отдельно скомпилировать `qca-nss-ecm` с полной feed patch series, проверить marker внутри `ecm.ko` и только затем планировать стендовые испытания. Аппаратные тесты — только на втором RD03v2; основной роутер не трогать.
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
