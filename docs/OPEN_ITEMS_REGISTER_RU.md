# Реестр незакрытых задач — Xiaomi AX3000T RD03v2

**Назначение:** единый список того, что осталось проверить, исправить, спроектировать или осознанно отложить. Этот файл — рабочий журнал, а не обещание готовности прошивки. Каждый пункт закрывается только по указанному критерию и с доказательством в CI, логе или протоколе стендового теста.

**Дата ревизии:** 2026-11-17
**Репозиторий:** `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`
**Рабочая ветка:** `work/rd03v2-dualwan-mwan3-baseline`.

**Контрольная точка:** code/test HEAD: `5b3328e23d36b2b1089e4b2342e0a5255578e022`. Последующие изменения рабочей ветки после этой точки являются документационными и не меняют прошивочные исходники, конфигурацию, патчи или исполняемую логику тестов.
**Current source/test candidate:** Source implementation 16193bfb29eecca103a370270458a779403ac619; patch-envelope repair f9f33b314ef11ad42037ad81de18e05f6e0e11f3; functional test-harness commit 0ca5b790cded21107f4ca72b987d3129790a9b18; latest comment-only / CI-trigger commit 5b3328e23d36b2b1089e4b2342e0a5255578e022 (no test or firmware behavior change). Current patch blob 3dbe8c97bdab7ee7452fc49b4ae77580788ef659; current test-harness blob dbb7859aed90d1b125de28801dd44d6826d3a2fe. Code/test HEAD `5b3328e23d36b2b1089e4b2342e0a5255578e022`. Последующие изменения рабочей ветки после этой точки затрагивали только документацию. Gate-first callback and drain-loop implementation is committed but has not passed exact QSDK archive apply or C compilation.
**Устройство:** только Xiaomi AX3000T RD03v2 / Qualcomm IPQ5018. Не переносить выводы и образы на другие аппаратные ревизии.

## Текущая контрольная точка — 2026-11-17

- Рабочая ветка: work/rd03v2-dualwan-mwan3-baseline.
- Source implementation 16193bfb29eecca103a370270458a779403ac619; patch-envelope repair f9f33b314ef11ad42037ad81de18e05f6e0e11f3; functional test-harness commit 0ca5b790cded21107f4ca72b987d3129790a9b18; latest comment-only / CI-trigger commit 5b3328e23d36b2b1089e4b2342e0a5255578e022 (no test or firmware behavior change). Current patch blob 3dbe8c97bdab7ee7452fc49b4ae77580788ef659; current test-harness blob dbb7859aed90d1b125de28801dd44d6826d3a2fe. Code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022; subsequent documentation-only branch revisions; the two commits after code/test HEAD (58332b37d5ce7acf81b11dbfd8ec537423fbd323 and ffb68d29abd777bed44cb113887649fe88557698) are documentation-only.
- Последующие документационные изменения после code/test checkpoint не меняют прошивочные исходники, конфигурацию, патчи или исполняемую логику тестов.
- Candidate 9002 закрывает per-family gate непосредственно в atomic callback на первом ADD/DEL событии, использует readiness barrier для initial FIB replay, drain-loop worker, RTNL-serialized final gate release и teardown cleanup.
- Callback закрывает gate до публикации pending bit. Повторные события coalesce и не увеличивают temporary-stop counter повторно. Во время initial register_fib_notifier replay callback не queue-ит worker; после успешного return caller выставляет ready и ставит один worker.
- Worker обрабатывает pending IPv4/IPv6 bits циклом и открывает gates только после пустого pending snapshot под per-net RTNL. Teardown disarm-ит queueing, unregister-ит notifier, drain/cancel-ит work и очищает остаточные gated/pending state.
- Это source candidate, а не подтверждённое исправление: exact QSDK archive apply, полная отсортированная 32-patch queue, C compilation, fault injection, lockdep/KASAN и runtime stress после изменения не выполнялись. Порядок RTNL → ECM frontend spinlock ещё должен быть подтверждён lockdep.
- Последний GitHub Actions run — #129, отменён до jobs. #127 прошёл Static/PREPARE_ONLY, но full-build прерван runner shutdown (exit 143). #124 — последняя сборка с образами; она собрала старую версию ECM, а final verify-v2 завершился FAIL.
- Read-only GitHub API snapshot (2026-11-17): 129 Actions runs exist; #129 (SHA e398b3f598b6b4adcabd2e7d99fc5b2c7ce4991b) remains the latest and was cancelled before jobs. No run is associated with code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022; the combined commit-status list is empty for code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022. The [full-build] marker on the comment-only commit did not produce a visible #130 run. The API does not expose why no run was created. The last UI observation (2026-11-16) reported a usage-related pause, but that state has not been rechecked in the UI. Manual dispatch remains untested. Workflow contains manual workflow_dispatch with `full_build=false/true`, but neither variant has run on the current code/test revision.
- NOT TESTED: exact archive apply, 32-patch feed series после нового изменения, текущая C compilation, initial replay/retry, injected IPv4/IPv6/FIB registration failures, worker churn stress, module load/unload, firewall4/mwan3 failover, conntrack marks, NSS datapath, throughput/RTT/loss, game traffic, soak и recovery.
- Основной домашний роутер остаётся на stock MiWiFi. CI-образы используют временный P-256 key и example.invalid; это не installable release и их нельзя прошивать.

## Оценка зрелости проекта — 2026-11-17

**Инженерный прогресс: 44%. Готовность к установке как пользовательского релиза: около 10%.**

Оценка — взвешенная инженерная модель, а не процент строк кода или число тестов:

| Область | Вес | Выполнено в области | Вклад |
|---|---:|---:|---:|
| Унаследованная платформа RD03v2/NSS | 15% | 100% | 15,0 п.п. |
| Собственные source/config изменения Dual-WAN и ECM | 35% | 68% | 23,8 п.п. |
| Сборка и CI на актуальной ревизии | 20% | 25% | 5,0 п.п. |
| Runtime Dual-WAN, FIB notifier и NSS datapath | 15% | 0% | 0 п.п. |
| Аппаратные измерения, latency/loss и стабильность | 10% | 0% | 0 п.п. |
| Подписанный релиз, repository и recovery-процедура | 5% | 10% | 0,5 п.п. |
| **Итого** | **100%** |  | **44,3% (округлено до 44%)** |

Унаследованная платформа уже имеет отдельные результаты upstream build/hardware validation. Эти результаты не засчитываются как проверка новых Dual-WAN/ECM изменений. Текущая gate-first/drain-loop версия patch 9002 новее исходников, собранных в CI #124, и пока не прошла повторный apply/compile/verify. Поэтому 44% означает завершённость инженерной работы, а не готовность безопасно прошивать устройство.

## 1. Краткий итог аудита

Проект находится в состоянии **экспериментальной source/build baseline**, а не готовой прошивки Dual-WAN/NSS для установки.

Подтверждено:
- В конфигурацию добавлены `mwan3` 2.12.5, `luci-app-mwan3`, nft-backed iptables/ip6tables/xtables, ipset и требуемые расширения.
- В активном feed-overlay есть ECM patch 9001 и отдельный RD03v2/QSDK 14.0 patch 9002 для FIB policy-rule ADD/DEL.
- CI #123/#124 подтвердили применение и сборку предыдущей реализации patch 9002 на hash-verified QSDK source после полной сортированной очереди из 32 ECM-патчей. Текущие изменения транзакционного rollback появились позже и ещё не прошли повторный CI.
- CI #124 собрал предыдущую версию `qca-nss-ecm`, включил `kmod-qca-nss-ecm` в rootfs, создал sysupgrade и initramfs-factory images; FIB notifier marker найден внутри image `ecm.ko`; rootfs содержал 223 пакета. Это не компиляция текущего транзакционного rollback patch.
- CI #127 прошёл Static checks и PREPARE_ONLY, включая ECM preflight и ordered 32-patch queue.

Не подтверждено:
- Финальный `verify-v2` на актуальном code/test HEAD.
- Повторный полный build после исправлений watchdog и AUTOREMOVE verifier.
- Runtime загрузка/выгрузка ECM и реальная регистрация notifier.
- Работа nft-compatible mwan3 на firewall4 и реальный failover двух WAN.
- Сохранение/поведение существующих conntrack-сессий, fwmark/NSS acceleration.
- Производительность, задержка, потери и стабильность под нагрузкой на реальном RD03v2.
- Готовый подписанный release/repository и проверенная процедура установки/отката именно этого экспериментального Dual-WAN baseline.

**Критически важно:** CI #124 завершился FAIL на финальном verifier. CI #127 был прерван runner shutdown с кодом 143 до получения compile/final-verifier результата. CI #128/#129 отменены до создания jobs. Code/test HEAD `5b3328e23d36b2b1089e4b2342e0a5255578e022` и branch HEAD `ffb68d29abd777bed44cb113887649fe88557698` не имеют нового run/status; актуальная gate-first/drain-loop реализация не прошла full CI. Read-only GitHub API snapshot (2026-11-17): 129 Actions runs exist; #129 (SHA e398b3f598b6b4adcabd2e7d99fc5b2c7ce4991b) remains the latest and was cancelled before jobs. No run is associated with code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022; the combined commit-status list is empty for code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022. The [full-build] marker on the comment-only commit did not produce a visible #130 run. The API does not expose why no run was created. The last UI observation (2026-11-16) reported a usage-related pause, but that state has not been rechecked in the UI. Manual dispatch remains untested. CI-образы используют временный P-256 ключ и `example.invalid`, не являются установочными релизами. Основной домашний роутер остаётся на stock MiWiFi.

## 2. CI: точное состояние и что запускать дальше

| Run | SHA | Результат |
|---|---|---|
| #124 | `bb3d25b8` | Static/PREPARE_ONLY и ECM preflight PASS; qca-nss-ecm compiled; оба типа образов созданы; final verify-v2 FAIL: watchdog 20 PASS / 26 FAIL и два false-negative ECM fingerprints после AUTOREMOVE |
| #125 | `f372d519` | Static остановился на `git diff --check`: дополнительная пустая строка в конце handoff; остальные jobs skipped |
| #126 | `0d2aeadb` | Та же whitespace-проблема; остальные jobs skipped |
| #127 | `faa82e24` | Static PASS и PREPARE_ONLY PASS; full-build начал `./build.sh`, но runner получил shutdown, exit 143; compile и verify-v2 не подтверждены |
| #128 | `e7846a1` | Cancelled до создания jobs |
| #129 | `e398b3f` | Cancelled до создания jobs |

Исторический коммит `49d3579` добавил обязательную проверку `CONFIG_AUTOREMOVE=y` перед принятием fallback по копиям патчей в feed. Это изменение ещё не получило завершённой full-build проверки.

### CI-01 — Получить завершённый full CI на code/test HEAD

**Приоритет:** P0 — блокирует любые заявления о завершённой сборке и переход к прошивке.

**Текущий статус:** active patch blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659` (implementation `16193bfb29eecca103a370270458a779403ac619`, envelope repair `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`); current test harness blob `dbb7859aed90d1b125de28801dd44d6826d3a2fe` (functional commit `0ca5b790cded21107f4ca72b987d3129790a9b18`, latest comment-only / CI-trigger commit `5b3328e23d36b2b1089e4b2342e0a5255578e022`). Code/test HEAD `5b3328e23d36b2b1089e4b2342e0a5255578e022`; subsequent branch revisions are documentation-only. Read-only GitHub API snapshot (2026-11-17): 129 Actions runs exist; #129 (SHA e398b3f598b6b4adcabd2e7d99fc5b2c7ce4991b) remains the latest and was cancelled before jobs. No run is associated with code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022; the combined commit-status list is empty for code/test HEAD 5b3328e23d36b2b1089e4b2342e0a5255578e022. The [full-build] marker on the comment-only commit did not produce a visible #130 run. The API does not expose why no run was created. The last UI observation (2026-11-16) reported a usage-related pause, but that state has not been rechecked in the UI. Manual dispatch remains untested.

Действия:
1. Maintainer должен повторно включить Actions в UI репозитория. После этого запустить manual dispatch на точном branch ref: сначала `full_build=false`, затем `true`. Не создавать пустые или документационные коммиты ради запуска.
2. Проверить все jobs: Static, PREPARE_ONLY, ECM preflight, полный `qca-nss-ecm` build, image generation и final `verify-v2`.
3. Сохранить build-log artifact и PREPARE_ONLY artifact; записать SHA, run ID, runner outcome и все PASS/FAIL.
4. Если runner снова остановится с 143, выяснить причину завершения отдельно от ошибок компиляции; не классифицировать это как source failure.

**Критерий закрытия:** успешный полный workflow на текущем code/test SHA, ноль FAIL в `verify-v2`, доступные и разобранные логи/артефакты. PREPARE_ONLY PASS или одна лишь компиляция не закрывают этот пункт.

### CI-04 — Добавить и проверить безопасный ручной запуск полной валидации

**Приоритет:** P1; снимает необходимость в искусственном source-коммите, когда нужно проверить неизменившийся code/test SHA.

Workflow уже обновлён: добавлен `workflow_dispatch` с boolean input `full_build`. Значение `false` (default) должно запускать только Static + PREPARE_ONLY; `true` — также full-build + `verify-v2`. Ручной запуск из любого ref, кроме `work/rd03v2-dualwan-mwan3-baseline`, отклоняется. Обычный push-trigger с `[full-build]` сохранён.

**Ограничение на текущей проверке (API snapshot 2026-11-17):** зарегистрировано 129 Actions runs; последний — #129, отменён до создания jobs. Запуск для code/test HEAD отсутствует, несмотря на `[full-build]` в commit message `5b3328e`; API не раскрывает причину. Последняя UI-проверка 2026-11-16 сообщала об ограничении использования Actions, но текущее состояние UI не перепроверено. Перед manual dispatch `full_build=false` и `true` maintainer должен проверить страницу Actions и repository/workflow settings.

**Критерий закрытия:** после повторного включения Actions выполнить реальный manual dispatch с `full_build=false` и подтвердить, что full-build job пропущен; затем выполнить `true` и подтвердить full-build + final `verify-v2`. Сохранить run IDs и результаты. Существующие safeguards — ephemeral P-256 key, `example.invalid`, отсутствие публикации образов — должны остаться.

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

Старый verifier принимал наличие каталога build_dir за наличие patched ECM source, хотя `CONFIG_AUTOREMOVE=y` мог удалить файлы внутри. Исправление `e7846a1` проверяет реальный `ecm_db/ecm_db.c`; при его отсутствии сверяет exact patch bytes в подготовленном NSS feed. Исторический коммит `49d3579` дополнительно требует в итоговом `.config` ровно `CONFIG_AUTOREMOVE=y`.

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

### ECM-05 — Подтвердить транзакционный rollback при ошибках route/FIB notifier registration

**Приоритет:** P1; решение обязательно до аппаратного Dual-WAN acceptance.

Source revision `fb88ba4` исправляет fail-open и partial-init пути транзакционно. В `ecm_db_init()` результаты IPv4/IPv6 route notifier хранятся раздельно в `route_ret`; первая ошибка переносится в `ret` и не перезаписывается последующим вызовом. Флаги `ecm_db_ipv4_route_registered` и `ecm_db_ipv6_route_registered` устанавливаются только после успешной регистрации. Если одно семейство не регистрируется, `ecm_db_init()` вызывает `ecm_db_exit()`, который снимает только фактически зарегистрированное семейство, останавливает FIB worker и освобождает DB до возврата ошибки. FIB notifier регистрируется только после успешных route notifier; если он завершается ошибкой, DB также откатывается и `fib_ret` возвращается вызывающему коду.

Pinned QSDK 14.0 инициализирует ECM DB до IPv4/IPv6 packet frontends и conntrack notifier. Поэтому отказ notifier на этом этапе приводит к отказу загрузки ECM-модуля до включения его packet hooks, а не к оставлению частично работающего ECM/NSS datapath. Предыдущая схема с постоянно закрытыми frontend stop gates удалена.

**Что ещё требуется:** на точном QSDK archive проверить применение patch 9002 после полной сортированной ECM patch series; проверить raw `patch -f -p1` и offsets; собрать `qca-nss-ecm`; добавить/выполнить fault injection отдельно для IPv4 route notifier, IPv6 route notifier и FIB notifier; подтвердить first-error propagation, rollback только успешных notifier, drain worker, освобождение DB без leak/oops/deadlock и нормальную повторную загрузку модуля.

**Текущий статус:** transactional registration rollback и gate-first callback/drain-loop находятся в active patch 9002 (implementation `16193bfb29eecca103a370270458a779403ac619`, envelope repair `f9f33b314ef11ad42037ad81de18e05f6e0e11f3`, blob `3dbe8c97bdab7ee7452fc49b4ae77580788ef659`). Current harness blob `dbb7859aed90d1b125de28801dd44d6826d3a2fe` включает source guards и 32-patch queue check; functional harness commit `0ca5b790cded21107f4ca72b987d3129790a9b18`, последний comment-only / CI-trigger commit `5b3328e23d36b2b1089e4b2342e0a5255578e022`. Строгая проверка envelope/hunk counts после ремонта PASS (9 sections, 22 hunks); exact archive apply/full-series preflight, C compilation, runtime fault injection и module load/unload — **NOT TESTED**. ECM-05 остаётся открытым до CI и fault-injection evidence.

### ECM-06 — Gate-first FIB callback и drain всех pending worker passes

**Приоритет:** P1; source candidate реализован, validation gate открыт.

**Исходный риск:** один worker pass мог снять pending snapshot, выполнить defunct и открыть frontend gate, пока новое FIB rule событие уже поставило тот же work item повторно. Следующий pass начинался только после завершения текущего. Отдельно существовала задержка между callback и началом worker, когда новые flows могли попасть в ECM до закрытия gate.

**Candidate implementation в patch code commit 16193bfb29eecca103a370270458a779403ac619:**
1. Первый callback для IPv4/IPv6 атомарно устанавливает per-family gated-state bit и синхронно закрывает соответствующий frontend temporary-stop gate. Повторные события не увеличивают временный stop counter повторно.
2. Во время initial FIB dump/replay callback записывает pending/gated state, но не запускает worker, пока register_fib_notifier() не вернётся. После успешной регистрации WRITE_ONCE(ready, true) и один schedule_work() запускают обработку replay-событий.
3. Worker обрабатывает pending IPv4/IPv6 bits циклом. Gate остаётся закрытым между проходами. Открытие выполняется только после пустого pending snapshot под per-net RTNL, сериализованного с live FIB rule ADD/DEL callbacks.
4. Teardown disarm-ит queueing, снимает notifier, ждёт/cancel-ит work и под RTNL снимает остаточные pending/gated bits и temporary-stop refs.

 **Результат ручного аудита lock order — 2026-11-16:** exact pinned QSDK source commit `7894b769eeb64f1c44fde547a107a8b866997590` получен из source mirror; GitLab repository tree содержит 81 C-файл. Уточнение по объёму: это число файлов в дереве, а не утверждение, что каждый из 81 файлов был вручную загружен и полностью просмотрен. Прямой разбор выполнен для восьми `frontends/cmn/` translation units, где обнаружены захваты `ecm_ipv4_lock`/`ecm_ipv6_lock` (common, multicast, non-ported и ported для IPv4/IPv6), а также для `ecm_interface.c`, `ecm_db_connection.c`, `ecm_db.c`, `ecm_db_listener.c` и `ecm_notifier.c`. В восьми family-lock translation units прямых `rtnl_lock()`/`rtnl_net_lock()` acquisition или `ASSERT_RTNL*` нет. В `ecm_interface_register_nf_hook_wlan_device()` файла `ecm_interface.c` есть отдельный `rtnl_lock()`, без прямого захвата family lock в этом пути.

**Косвенный callback-путь проверен отдельно.** Некоторые ECM packet paths удерживают family lock при вызове `ecm_db_connection_add()`. Эта функция синхронно вызывает listener callbacks до возврата вызывающему коду. В штатном ECM DB зарегистрирован один listener: node/host/mapping callbacks равны `NULL`, connection callbacks ведут в `ecm_notifier_connection_added/removed`. `ecm_notifier_connection_added()` сначала проверяет `ecm_notifier_count` и при нуле возвращается до вызова atomic notifier chain. В PREPARE_ONLY artifact run #127 (`14185375390`, SHA-256 ZIP `5f29e8a7554d2dc035410eedd1fd92c0da615bed348e78ead910ace23c11e0d7`) итоговый `.config` содержит `# CONFIG_PACKAGE_kmod-ipsec is not set`, `# CONFIG_PACKAGE_kmod-ipt-ipsec is not set` и `# CONFIG_NSS_DRV_IPSEC_ENABLE is not set`. Pinned NSS feed также не содержит выбранного IPsec/XFRM kernel package. Поэтому известный внешний NSS IPsec XFRM notifier client не входит в текущий образ; его callback не является активным путём целевой конфигурации. При будущем включении IPsec/XFRM либо добавлении другого ECM notifier subscriber этот call graph необходимо перепроверить.

В `tools/test-ecm-fib-rule-patch.sh` guard усилен: он консервативно проверяет весь translation unit, если тот содержит family-lock acquisition, и запрещает в нём прямые RTNL acquisition/assertion calls. Его встроенные parser self-tests проверяют string/character literals, комментарии, альтернативную ветвь unlock, `ASSERT_RTNL` и вызов в другой функции того же translation unit; отдельно проверен чистый случай без RTNL. Дополнительный IPsec config predicate self-tests все три запрещённых symbols на synthetic `=m` и проверяет, что explicit `not set` не блокируется. Локально прогнан точный Python guard block: parser self-tests PASS, чистый source fixture PASS, synthetic alternate-branch inversion корректно обнаруживается. Отдельный `bash -n` и config tests PASS на фактическом `config.final.txt` run #127, на каждом из трёх synthetic `=m` и на disabled config. Это локальные тесты guard-фрагментов, не полный shell harness и не CI. Косвенные helper paths, runtime lockdep/KASAN и fault injection остаются NOT TESTED.

**Что нужно доказать:**
- exact QSDK archive apply и применение всей отсортированной 32-patch ECM feed series;
- корректность callback context: gate helper должен оставаться строго atomic-safe;
- отсутствие lock inversion при порядке RTNL → frontend spinlock (lockdep);
- корректность initial replay/retry и событий между регистрацией notifier и readiness barrier;
- детерминированные события после snapshot, во время synchronize_net(), во время DB defunct и перед final gate release;
- отказ IPv4/IPv6 route notifier и FIB notifier, unload во время pending work, repeated load/unload;
- C compilation и отсутствие oops/warnings/leaks/deadlock на аппаратном стенде.

**Критерий закрытия:** exact apply + full feed series + C compile PASS; source/fault tests PASS; lockdep/KASAN без ошибок; ни один family gate не открывается при pending events; module teardown не оставляет worker/gate reference.

**Текущий статус:** patch/test source candidate committed; CI, compile, fault injection и hardware runtime — **NOT TESTED**. ECM-06 остаётся открытым.

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

Ранее были обнаружены stale claims в `DEVELOPMENT_MANUAL_RU.md` и `ecm-policy-routing-port.md`: они говорили, что patch 9002 отсутствует/не применялся, хотя он уже в overlay, прошёл preflight и скомпилировался в CI #124. Эти места обновлены. Поддерживать register и handoff синхронными. Дополнительно перепроверять README: release/install ссылки ведут на upstream ADCDS releases, а не на экспериментальный Dual-WAN branch; это различие должно оставаться явным, чтобы не создавать впечатление, что ветка прошла acceptance.

### MAINT-04 — Решить вопрос branch protection и обязательных CI checks

**Приоритет:** P2; не блокирует работу прошивки напрямую.

На live-проверке GitHub branch API для `work/rd03v2-dualwan-mwan3-baseline` вернул `protected=false`; required status checks отсутствуют. Это может быть допустимо для экспериментальной ветки, но сейчас ничто на стороне GitHub не запрещает продвинуть коммит без обязательного CI gate.

**Действия:** решить, какие защиты нужны для `main` и будущей release-ветки; после стабилизации CI подключить обязательные статические проверки и full-build/verify gate там, где это практически возможно. Не включать жёсткую защиту на экспериментальной ветке до тех пор, пока workflow не станет воспроизводимым и доступным для ручного запуска.

**Критерий закрытия:** принято и документировано решение по branch protection; required checks настроены на защищаемых стабильных ветках либо явно зафиксировано, почему они пока не используются.

## 8. Рекомендуемый порядок работ

1. **CI-04 → CI-01 → CI-02 → CI-03:** получить управляемый manual trigger, затем завершённый CI и final `verify-v2` на актуальном code/test SHA.
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
