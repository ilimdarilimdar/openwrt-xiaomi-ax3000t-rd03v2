# Передача проекта следующему ИИ-агенту: Xiaomi AX3000T RD03v2

> **Назначение файла:** единая точка входа и рабочая опорная запись для любого следующего ИИ-агента, который продолжит разработку этой прошивки. Сначала прочитать этот файл, затем сверить живое состояние GitHub. Не считать сведения ниже неизменными: SHA, очередь CI и состояние сборки необходимо обновлять перед каждым действием.

**Последняя сверка исходного состояния:** 2026-11-15, примерно 07:30 UTC  
**Последнее обновление журнала CI:** 2026-11-15, примерно 07:55 UTC  
**Репозиторий:** `ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2`  
**Рабочая ветка:** `work/rd03v2-dualwan-mwan3-baseline`  
**Последний подтверждённый firmware source/config commit:** `f5e828fa1cceb123fee81a1bafe5c9a71d0a81fb`  
**Последний commit изменения CI workflow:** `472ed0ce1b2f2fa68c78f362edfc5b5f388bc7c7`  
**Последующие commits:** `4a0a9146086cebd4b8c8471870187c6986ae1de3` и `472ed0ce1b2f2fa68c78f362edfc5b5f388bc7c7` меняют только CI workflow; `50b15707fedc0354a6ac175352ba21a3f1985f9a`, `0a5ea92c8f80dd2e045954b2e225ea1d7c6b5501`, `16b01367564d62091a3e966b56c8629fd3ff94f0` и `bcfad8813a164a38f59444534cd7f4983d9d345` обновляют CI-документацию; `8039a4795cc66434e17deca5f76d0e9e8a1d4fc8`, `331ce2f8328c900bd777b426e098c2450e2f0c06` и `7b55792f980412afd6678e2539cd78496dbc0940` создали/уточнили handoff и ссылку README. Ни один из этих commits не меняет firmware source, kernel, NSS code patches или WAN config.

**Последний статус на момент аудита:** активная разработка; базовая конфигурация и автоматические проверки есть, полная сборка Dual-WAN-ветки и её аппаратная пригодность не подтверждены.

> Перед любым действием получить живой HEAD. Последующие обновления этого handoff тоже создают documentation-only commit и двигают branch HEAD; не считать такой сдвиг изменением firmware code.

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

GitHub compare от 2026-11-15 подтверждает: `main` находится на общей точке `14a07fbf317a00d2c592c7ffd262bcc3f4b6328c`; рабочая ветка уже содержит `main` (`behind_by=0`). В раннем запросе было `ahead_by=52`, в более позднем — `ahead_by=54`; разница объясняется новыми documentation-only commits, а не изменением firmware. Считать важным условием `behind_by=0`, а точное число ahead перепроверять перед PR/merge. Дополнительный merge/rebase из `main` сейчас не требуется. **Не сливать main автоматически** и не обновлять upstream pins попутно с текущей задачей.

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

Проверка GitHub Actions обновлена 2026-11-15 около 07:45 UTC.

| Workflow | Commit | Последний известный результат |
|---|---|---|
| #15 | `c5a64af9a23996401eb22c2a275023c419bbe547` | Static PASS; PREPARE_ONLY PASS; artifact inspected |
| #16 | `5bcad81cfe911b91f4ac928e53f424e1580ddfd7` | Static PASS; full build step IN PROGRESS |
| #29 | `f5e828fa1cceb123fee81a1bafe5c9a71d0a81fb` | CANCELLED by newer pushes |
| #34 | `4a0a9146086cebd4b8c8471870187c6986ae1de3` | CANCELLED by subsequent workflow fix |
| #35 | `472ed0ce1b2f2fa68c78f362edfc5b5f388bc7c7` | WAITING behind #16 |

Подробности:

- Артефакт #15: ID `14150612353`, `rd03v2-prepare-c5a64af9a23996401eb22c2a275023c419bbe547`. Извлечены `defconfig.log`, `config.final.txt`, `diffconfig.txt`, feed logs.
- В #15 `defconfig.log` подтвердил NSS цикл: `luci-app-nss -> kmod-qca-nss-drv -> kmod-qca-dsa-nss -> nss-tools-dwmac -> nss-tools -> luci-app-nss`. В том же логе есть Qt5, fwknopd и squeezelite recursive diagnostics. Это реальный результат старой ветки, а не догадка.
- Проверено, что #15 выполнялся на commit `c5a64af`, где патча `tree-patches/0014-luci-app-nss-use-ipq50xx-runtime-dependency-only.patch` ещё не существовало. Поэтому #15 **не** проверяет устранение NSS цикла патчем 0014.
- #15 также содержал override warnings для `ATH11K_MEM_PROFILE_256M` и `NSS_MEM_PROFILE_LOW`; в актуальном firmware config эти два выбора уже оставлены upstream-фрагменту `256m.config`, локально остаётся отдельный `ATH11K_NSS_MEM_PROFILE_256M`.
- В #16 checkout, runner resource check и генерация временного CI signing key завершились успешно. Job `Build and run verify-v2` всё ещё `in_progress`; лог недоступен до завершения, артефактов пока нет. Не объявлять сборку зависшей только из-за длительности: timeout настроен на 360 минут.
- #29 был отменён новыми push до получения подтверждённого артефакта актуального PREPARE_ONLY.
- В workflow найден и исправлен статический path typo: раньше проверка ссылалась на несуществующий `0014-luci-app-nss-use-ipq50xx-runtime.patch`; теперь путь совпадает с реальным именем `0014-luci-app-nss-use-ipq50xx-runtime-dependency-only.patch`. Исправление — commit `472ed0c`.
- Patch 0014 вручную проверен против файла `package/nss/luci-app-nss/Makefile` из upstream commit `c36db6321c11595dc45a160cdab36b5c2d787744`: его Git blob SHA `c7ac95edeb9c5147b9728573af9760d4b038d2f1` совпадает с индексом `c7ac95e` в patch; `git apply --check` PASS, применение без fuzz, итоговая зависимость `+luci-base +nss-tools-dwmac`. Это подтверждает применимость контекста, но не заменяет PREPARE_ONLY/Kconfig-проверку.
- Добавлен `paths-ignore` для Markdown и `docs/**` на push и pull_request. Смешанные изменения документации вместе с кодом всё равно запускают CI. Это должно прекратить расходование сериализованного слота на одни только README/мануалы.
- Workflow #35 на commit #472ed0c ожидает окончания #16; следующий запуск должен проверить исправленный static check и выполнить актуальный PREPARE_ONLY. Последующие документационные изменения не меняют firmware code.
- CI full-build использует disposable key и `example.invalid`, поэтому не является пользовательским образом. Аппаратной валидации нашей Dual-WAN-ветки нет.

Ссылки:

- [Actions workflow](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/workflows/rd03v2-validation.yml)
- [Run #15 — PREPARE_ONLY artifact](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686096014)
- [Run #16 — full build](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43686188656)
- [Run #35 — corrected workflow](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43690850704)

**Первое действие следующего агента:** проверить окончание #16, затем run #35. Скачать PREPARE_ONLY artifact #35 и убедиться, что NSS recursive cycle исчез, а оставшиеся warnings объяснены. Не начинать вторую полную сборку и не трогать основной роутер.

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
- Следующий шаг: проверить окончание #16 и run #35; получить свежий PREPARE_ONLY artifact после patch 0014; доказать исчезновение NSS цикла и классифицировать оставшиеся Kconfig diagnostics.



**Примечание к документационным обновлениям:** этот файл намеренно является живой записью. Любой следующий агент должен сохранять исторические SHA как контрольные точки, но всегда запрашивать актуальные refs и CI state из GitHub. Последующий сдвиг branch HEAD от обновления этого же файла — ожидаемый docs-only commit, не доказательство изменения firmware code.
