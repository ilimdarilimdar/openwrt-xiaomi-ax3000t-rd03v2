# Реестр незакрытых задач — Xiaomi AX3000T RD03v2

**Назначение:** единый список того, что осталось проверить, исправить, спроектировать или осознанно отложить. Этот файл — рабочий журнал, а не обещание готовности прошивки. Каждый пункт закрывается только по указанному критерию и с доказательством в CI, логе или протоколе стендового теста.

**Дата полной ревизии:** 2026-11-16  
**Репозиторий:** `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`  
**Рабочая ветка:** `work/rd03v2-dualwan-mwan3-baseline`  
**Code/test baseline:** `49d3579437389e2ffc111b94a08839ef7bd29ae7`  
**Branch HEAD на момент ревизии:** `e81dbad389ad558e72aab6c23295c72299a6d7fe` (после code/test baseline шли только документальные коммиты; это подтверждено GitHub compare).  
**Устройство:** только Xiaomi AX3000T RD03v2 / Qualcomm IPQ5018. Не переносить выводы и образы на другие аппаратные ревизии.

## 1. Краткий итог аудита

Проект находится в состоянии **экспериментальной source/build baseline**, а не готовой прошивки Dual-WAN/NSS для установки.

Подтверждено:
- В конфигурацию добавлены `mwan3` 2.12.5, `luci-app-mwan3`, nft-backed iptables/ip6tables/xtables, ipset и требуемые расширения.
- В активном feed-overlay есть ECM patch 9001 и отдельный RD03v2/QSDK 14.0 patch 9002 для FIB policy-rule ADD/DEL.
- CI #123/#124 подтвердили применение patch 9002 к hash-verified QSDK source и после полной сортированной очереди из 32 ECM-патчей, а также source-level lifecycle/atomic guards.
- CI #124 собрал `qca-nss-ecm`, включил `kmod-qca-nss-ecm` в rootfs, создал sysupgrade и initramfs-factory images; FIB notifier marker найден внутри image `ecm.ko`; rootfs содержал 223 пакета.
- CI #127 прошёл Static checks и PREPARE_ONLY, включая ECM preflight и ordered 32-patch queue.

Не подтверждено:
- Финальный `verify-v2` на актуальном code/test HEAD.
- Повторный полный build после исправлений watchdog и AUTOREMOVE verifier.
- Runtime загрузка/выгрузка ECM и реальная регистрация notifier.
- Работа nft-compatible mwan3 на firewall4 и реальный failover двух WAN.
- Сохранение/поведение существующих conntrack-сессий, fwmark/NSS acceleration.
- Производительность, задержка, потери и стабильность под нагрузкой на реальном RD03v2.
- Готовый подписанный release/repository и проверенная процедура установки/отката именно этого экспериментального Dual-WAN baseline.

**Критически важно:** CI #124 завершился FAIL на финальном verifier. CI #127 был прерван runner shutdown с кодом 143 до получения compile/final-verifier результата. CI #128/#129 отменены до создания jobs. Для code/test SHA `49d3579` нет отдельного workflow run и commit status. CI-образы используют временный P-256 ключ и `example.invalid`, не являются установочными релизами. Основной домашний роутер остаётся на stock MiWiFi.

## 2. CI: точное состояние и что запускать дальше

| Run | SHA | Результат |
|---|---|---|
| #124 | `bb3d25b8` | Static/PREPARE_ONLY и ECM preflight PASS; qca-nss-ecm compiled; оба типа образов созданы; final verify-v2 FAIL: watchdog 20 PASS / 26 FAIL и два false-negative ECM fingerprints после AUTOREMOVE |
| #125 | `f372d519` | Static остановился на `git diff --check`: дополнительная пустая строка в конце handoff; остальные jobs skipped |
| #126 | `0d2aeadb` | Та же whitespace-проблема; остальные jobs skipped |
| #127 | `faa82e24` | Static PASS и PREPARE_ONLY PASS; full-build начал `./build.sh`, но runner получил shutdown, exit 143; compile и verify-v2 не подтверждены |
| #128 | `e7846a1` | Cancelled до создания jobs |
| #129 | `e398b3f` | Cancelled до создания jobs |

Коммит `e31ca88` исправил trailing blank line. Code/test HEAD `49d3579` добавил обязательную проверку `CONFIG_AUTOREMOVE=y` перед принятием fallback по копиям патчей в feed. Этот SHA пока не имеет CI run/status.

### CI-01 — Получить завершённый full CI на code/test HEAD

**Приоритет:** P0 — блокирует любые заявления о завершённой сборке и переход к прошивке.

Действия:
1. Обеспечить Actions-triggering push или ручной запуск из GitHub Actions на точной актуальной code/test revision. Обычные документационные коммиты не подходят: workflow игнорирует `docs/**`.
2. Проверить все jobs: Static, PREPARE_ONLY, ECM preflight, полный `qca-nss-ecm` build, image generation и final `verify-v2`.
3. Сохранить build-log artifact и PREPARE_ONLY artifact; записать SHA, run ID, runner outcome и все PASS/FAIL.
4. Если runner снова остановится с 143, выяснить причину завершения отдельно от ошибок компиляции; не классифицировать это как source failure.

**Критерий закрытия:** успешный полный workflow на текущем code/test SHA, ноль FAIL в `verify-v2`, доступные и разобранные логи/артефакты. PREPARE_ONLY PASS или одна лишь компиляция не закрывают этот пункт.

### CI-02 — Подтвердить исправленный watchdog

**Приоритет:** P0.

В #124 из 46 watchdog scenarios прошло 20, 26 упало, потому что BusyBox applet dispatch обходил PATH stubs. Коммиты `f372d519` и `0d2aeadb` добавили absolute-stub dispatch и передачу `WD_TEST_STUB_DIR`. В #127 статические проверки прошли, но runtime suite не запускалась из-за прерванного full-build.

Дополнительно:
- Сейчас `verify-v2.sh` запускает watchdog scenario suite через `--env host`.
- `tools/test-watchdog.sh` поддерживает также `--env target` с image BusyBox через qemu, но этот путь не включён в final verifier.
- Init lifecycle suite в текущем verifier запускается host Python/shell path. Следует оценить запуск target BusyBox варианта.

**Критерий закрытия:** все сценарии host BusyBox PASS; target BusyBox suite либо добавлен в verifier и PASS, либо документированно обосновано, почему target path не является gate. Никаких вызовов реальных host hardware applets из тестового режима.

### CI-03 — Подтвердить AUTOREMOVE-aware ECM verifier

**Приоритет:** P0.

Старый verifier принимал наличие каталога build_dir за наличие patched ECM source, хотя `CONFIG_AUTOREMOVE=y` мог удалить файлы внутри. Исправление `e7846a1` проверяет реальный `ecm_db/ecm_db.c`; при его отсутствии сверяет exact patch bytes в подготовленном NSS feed. `49d3579` дополнительно требует в итоговом `.config` ровно `CONFIG_AUTOREMOVE=y`.

**Критерий закрытия:** full build на актуальном code/test SHA проходит обе ветви verifier logic без false positive/false negative; итоговые image/module checks проходят.

## 3. ECM/NSS: незакрытая техническая проверка

### ECM-01 — Разобрать GNU patch fuzz для patch 9002

**Приоритет:** P1.

В compile log CI #124 GNU patch сообщил fuzz 1–2 на нескольких hunks patch 9002:
- `ecm_db/ecm_db.c`: hunks #1/#2/#4, fuzz 1/1/2;
- `ecm_init.c`: hunks #2/#4, fuzz 1/2, включая insertion в `ecm_exit()`.

Это не доказывает ошибочное применение: CI #123/#124 source guards подтвердили notifier stop в `ecm_exit()`, перед conntrack/frontend teardown; фактическая компиляция #124 завершилась. Но чистое применение желательно.

**Действия:** сравнить каждый fuzz hunk с pinned QSDK 14.0 source, расширить контекст там, где возможно, повторить ровно OpenWrt `patch -f -p1` на чистом source и после полной feed queue. Не менять patch semantics только ради нулевого fuzz.

**Критерий закрытия:** либо patch применяется без fuzz и проходит прежние lifecycle guards, либо сохраняется обоснование конкретного fuzz с exact applied-source excerpts и regression assertions.

### ECM-02 — Runtime load/unload и регистрация FIB notifier

**Приоритет:** P1; выполнять только после CI-01–CI-03.

На втором RD03v2 проверить:
- загрузку ECM и фактическую строку регистрации notifier в kernel log;
- поведение при ошибке `register_fib_notifier()` и чёткий warning;
- нормальную выгрузку, init unwind и повторную загрузку;
- отсутствие kernel oops, lockdep warning, hung workqueue и зависания teardown;
- состояние NSS/ECM до/после операции.

Строка marker в `ecm.ko` доказывает наличие кода при компиляции, но не успешную runtime-регистрацию на плате.

**Критерий закрытия:** повторяемые load/unload/reload циклы без ошибок, notifier register/unregister подтверждены логом, состояние datapath и counters сохранено.

### ECM-03 — FIB notifier initial replay и churn stress

**Приоритет:** P1.

Linux 6.18 `register_fib_notifier()` сначала выполняет initial FIB dump и replay существующих rules как ADD. Patch 9002 не отличает replay от live ADD; возможен широкий defunct проход при инициализации ECM. Это не объявляется дефектом без измерений, но требует проверки.

Действия:
1. Загрузить ECM при обычных local/main/default IPv4/IPv6 rules и измерить число/время defunct.
2. Повторить reload при активных ускоренных потоках.
3. Организовать быстрое изменение правил во время notifier registration/retry.
4. Проверить 800 rule changes / 4.4 s как ориентир из v1 отчёта, но не переносить v1 PASS на v2.
5. Проверить pending-bit coalescing, повторное планирование worker, RTNL ordering, `synchronize_net()`, unregister + `cancel_work_sync()`.
6. Сохранить dmesg, lockdep, workqueue state, counters, CPU, RAM, throughput и latency.

**Критерий закрытия:** отсутствуют deadlock/oops/warnings и потерянные события; ускоренные flows инвалидируются ожидаемо; измерено окно slow-path/re-acceleration.

### ECM-04 — Проверить mark classifier в живом datapath

**Приоритет:** P1.

Pinned qca-nss-ecm Makefile включает `ECM_CLASSIFIER_MARK_ENABLE=y` для qualcommax. PREPARE_ONLY подтверждает target/package selection, но это не доказывает корректную работу fwmark/CONNMARK с mwan3 или фактический NSS offload.

**Критерий закрытия:** conntrack mark, policy rule, физический WAN egress и ECM/NSS counters совпадают для flows через WAN1 и WAN2; отдельно проверены flows, которые не должны ускоряться.

## 4. Dual-WAN/mwan3: функции и ограничения

### DW-01 — Runtime firewall4/nftables совместимость mwan3

**Приоритет:** P1; только на втором RD03v2.

Проверить при двух поднятых WAN:
- `iptables --version` и `ip6tables --version` выдают `nf_tables`;
- запуск mwan3 создаёт ожидаемые IPv4/IPv6 mangle chains и ipsets;
- `nft list ruleset` одновременно показывает firewall4 и xtables-managed таблицы;
- `mwan3 status`, `ip -4 rule`, `ip -6 rule`, все route tables соответствуют плану;
- restart/ifdown/ifup не ломает и не дублирует chains/sets.

**Критерий закрытия:** артефакты команд, firewall/nft snapshot, логи и повторные циклы подтверждают стабильную конфигурацию.

### DW-02 — Проверить оба вида failover и оба направления

**Приоритет:** P1.

Не смешивать два события:
- tracker `disconnected` может перестроить mangle policy, не удаляя route rules; patch 9002 может не получить FIB rule event;
- реальный netifd `ifdown`/cable pull удаляет routes/rules и может породить FIB ADD/DEL.

Проверить WAN1→WAN2 и WAN2→WAN1 отдельно; отдельно физический link loss и upstream health-check loss. Во время теста снимать `ip rule`, all routing tables, mwan3 status, conntrack marks, captures, ECM/NSS counters и kernel log.

**Критерий закрытия:** новые flows используют доступный WAN после каждого типа отказа и возврата; существующие flows классифицированы как сохранённые, разорванные или зависшие с точной причиной. Нельзя заявлять seamless migration без доказательства.

### DW-03 — Решить судьбу conntrack CLI и selective cleanup

**Приоритет:** P1 — архитектурное решение, реализация только после отдельного review.

Текущий образ не выбирает userspace `conntrack` CLI. `iptables-mod-conntrack-extra` — xtables/kernel extension, а не CLI. Patch 9002 не очищает и не переписывает conntrack marks. Selective WAN-mark cleanup **не реализован**.

Варианты:
- оставить это ограничением базового проекта и документировать потерю/разрыв existing flows;
- отдельно добавить pinned `conntrack-tools` 1.4.8 и безопасный hook, который валидирует mwan3 ID/mask и fail-closed удаляет только нужные entries.

Глобальный `flush_conntrack` не использовать как замену: он может оборвать несвязанные с отказавшим WAN соединения.

**Критерий закрытия:** принятое решение записано; если добавляется код — отдельные тесты IPv4/IPv6, правильного mwan3 mark/mask, отсутствующей утилиты и fail-closed. До этого feature остаётся NOT IMPLEMENTED.

### DW-04 — Проверить агрегирование, не путать его с bonding

**Приоритет:** P1.

mwan3 распределяет независимые flows/соединения и failover; он не объединяет два независимых WAN в один более быстрый TCP flow. Несколько parallel flows могут распределяться и дать суммарную загрузку двух линий. Для единого потока потребуется отдельная архитектура (например, MPTCP или туннель/серверный агрегатор), со своими endpoint, CPU, latency и NSS trade-offs.

**Критерий закрытия:** измерены single-stream и multi-stream отдельно; цель проекта явно фиксирует, достаточно ли aggregate throughput по параллельным потокам или требуется отдельный bonding/MPTCP design. Нельзя обещать удвоение скорости одного TCP-потока от mwan3.

### DW-05 — IPv4 и IPv6 отдельно

**Приоритет:** P1.

Конфигурация запрашивает `CONFIG_IPV6=y` и multiple routing tables; это не доказывает, что оба ISP дают рабочий IPv6. На стенде проверить IPv4 обязательно, IPv6 — только с реальным рабочим uplink/prefix. Отсутствие IPv6 зафиксировать как NOT APPLICABLE для WAN-теста, не как PASS.

**Критерий закрытия:** отдельные route/rule, tracker, firewall, failover и traffic evidence для каждого реально поддерживаемого family.

### DW-06 — Измерить скорость, задержку, NSS и game traffic

**Приоритет:** P1 после базового failover.

Снять baseline WAN1 only и WAN2 only, затем weighted multi-flow. Сравнить NSS on/off, CPU, RAM, counters, p50/p95/p99 RTT, jitter, loss и throughput. Под игровой нагрузкой оценить, не ухудшает ли balancing ping и стабильность; не балансировать один game flow между uplinks без проверки source-IP/session semantics.

**Критерий закрытия:** повторяемые результаты, понятная политика для latency-sensitive flow и зафиксированные лимиты. Отдельно зафиксировать, что VPN/AWG traffic не следует считать NSS-accelerated без специальных доказательств.

## 5. Аппаратный стенд и стабильность

### HW-01 — Подготовить безопасный второй RD03v2 и recovery

**Приоритет:** P0 перед любыми операциями записи во flash.

Нужны:
- визуальное подтверждение RD03v2;
- проверенный образ и SHA-256;
- backup текущей конфигурации;
- проводной доступ;
- локальная процедура возврата/восстановления и независимое питание;
- заранее проверенные условия recovery именно для этой ревизии.

Главный домашний роутер оставить на stock MiWiFi. Ни один текущий CI artifact не прошивать.

**Критерий закрытия:** recovery path проверен и описан до первого экспериментального flash.

### HW-02 — Первичная загрузка и длительный soak

**Приоритет:** P1 после HW-01 и полного CI.

Проверить LAN/DSA, оба радиодиапазона, LuCI/SSH, WAN, DHCP/DNS, firewall, NSS startup, watchdog, reboot/cold boot и повторные потери линка. Провести многочасовой и затем много-дневный soak; собирать RAM trend, dmesg, unexpected reboot, watchdog receipts, UBI/NAND состояние.

**Критерий закрытия:** заранее определённый период без необъяснимых reboot/oops/panic, стабильное восстановление WAN/LAN/Wi-Fi и доказанный доступ к recovery.

## 6. Release / упаковка / публикация

### REL-01 — Реальный подписанный build

**Приоритет:** P1 до публичной установки.

Нужны постоянный signing key под контролем владельца, правильный публичный ключ в образе, реальный HTTPS `packages.adb` URL, согласованные package/kernel versions, hashes, manifests и отсутствие `example.invalid`. Приватный ключ не хранить в Git и не пересылать в чат.

### REL-02 — Пройти release pipeline end-to-end

**Приоритет:** P2 после REL-01.

Проверить `finish-build-v2.sh`, `mkrelease-v2.sh`, `verify-artifacts.py` в режимах release/published/device/packages, package repository indexing/signature, `publish-repo.sh` staging и безопасную публикацию. Сейчас нет доказательства, что этот экспериментальный Dual-WAN baseline оформлен как опубликованный release.

**Критерий закрытия:** локальная сборка release проходит полный verifier, repository доступен и его подписи проверены, install/upgrade/rollback проверены на отдельном RD03v2, release notes содержат реальные NOT TESTED.

## 7. Известные не блокирующие замечания и обслуживание

### MAINT-01 — Kconfig recursive dependency diagnostics

**Приоритет:** P2.

В PREPARE_ONLY остаются три diagnostics для Qt5 GUI, fwknopd/LuCI fwknopd и squeezelite-custom; эти пакеты не выбраны в final `.config`. После изменений feeds/config перепроверить, что это всё ещё unrelated и NSS dependency cycle не вернулся. Не удалять warning без анализа.

### MAINT-02 — Обновления upstream и security review

**Приоритет:** P2, периодически.

Пины зафиксированы: OpenWrt/NSS base, NSS feed, packages/LuCI feeds, QSDK ECM source, kernel 6.18.55. Не делать автоматический массовый bump. Для каждого обновления нужен diff/changelog review, повторное применение всех patches, Kconfig/preflight/full build и аппаратная регрессия затронутых узлов.

### MAINT-03 — Контроль актуальности документации

**Приоритет:** P2.

Ранее были обнаружены stale claims в `DEVELOPMENT_MANUAL_RU.md` и `ecm-policy-routing-port.md`: они говорили, что patch 9002 отсутствует/не применялся, хотя он уже в overlay, прошёл preflight и скомпилировался в CI #124. Эти места обновляются в рамках ревизии. Дальше поддерживать этот register и handoff синхронными.

## 8. Рекомендуемый порядок работ

1. **CI-01 → CI-02 → CI-03:** завершённый CI и final `verify-v2` на актуальном code/test SHA.
2. **HW-01:** только после этого подготовить второй RD03v2 и recovery.
3. **ECM-02 → ECM-03 → ECM-04:** подтвердить реальное ECM/NSS FIB behavior и mark datapath.
4. **DW-01 → DW-02:** сначала firewall/mwan3 и failover без balancing.
5. **DW-03:** принять решение о conntrack handling; не скрывать отсутствие selective cleanup.
6. **DW-05 → DW-06 → DW-04:** IPv4/IPv6, latency/performance, затем реальная потребность в агрегировании одного потока.
7. **HW-02:** soak/reboot/recovery.
8. **REL-01 → REL-02:** только после software/hardware gates — release и публикация.

## 9. Definition of Done

Нельзя объявлять проект готовым только потому, что:
- PREPARE_ONLY прошёл;
- ECM patch применился;
- `ecm.ko` скомпилировался;
- marker notifier есть в module;
- оба image-файла созданы.

Для релиза должны быть отдельно PASS: полный build/verifier, image/package/signature integrity, аппаратный boot/recovery, firewall4/mwan3 runtime, WAN1 и WAN2, failover events, ECM runtime, NSS counters/throughput, latency/loss, stability soak и release repository. Остальное явно остаётся NOT TESTED или NOT IMPLEMENTED.

---

**Правило обновления реестра:** при каждом закрытии задачи указать дату, code/test SHA, CI run ID или hardware test ID, evidence/log path и конкретный результат. Не закрывать задачу на основании предположения или соседнего, но не того SHA.
