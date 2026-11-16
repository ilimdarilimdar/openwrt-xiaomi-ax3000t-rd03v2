# План испытаний и приёмки Xiaomi AX3000T RD03v2 Custom Firmware

**Назначение:** воспроизводимая последовательность проверок собственной ветки OpenWrt/NSS с mwan3 до установки, во время стендовой эксплуатации и перед выпуском.

**Целевая платформа:** Xiaomi Mi Router AX3000T, аппаратная ревизия RD03v2, Qualcomm IPQ5018, 256 MiB RAM, NAND.

**Базовое правило:** каждый этап имеет отдельный результат. Успешная проверка исходников не означает успешную сборку; успешная сборка не означает корректную работу на плате; работа на плате не означает готовность релиза.

---

## 1. Статусы проверки

Использовать только следующие статусы:

- **PASS** — проверка выполнена, критерии пройдены, доказательства сохранены.
- **FAIL** — проверка выполнена, критерий не пройден.
- **NOT TESTED** — проверка не запускалась.
- **INCONCLUSIVE** — данных недостаточно или результат неоднозначен.
- **NOT APPLICABLE** — проверка объективно не относится к конфигурации.

Не заменять NOT TESTED на PASS. Не называть образ «стабильным» по одному успешному запуску.

## 2. Текущий подтверждённый baseline

Снимок состояния на 16.11.2026 по GitHub Actions и рабочей ветке
`work/rd03v2-dualwan-mwan3-baseline`. Code/test HEAD: `49d3579437389e2ffc111b94a08839ef7bd29ae7`.

| Этап | Результат |
|---|---|
| CI #124 Static checks | **PASS** |
| CI #124 PREPARE_ONLY + QSDK raw apply + full 32-patch ECM queue + lifecycle/atomic guards | **PASS** |
| CI #124 qca-nss-ecm C compilation and module packaging | **PASS** |
| CI #124 sysupgrade + initramfs-factory image generation | **PASS** |
| FIB notifier marker inside image `ecm.ko`; 223 rootfs packages | **PASS** |
| CI #124 final `verify-v2` | **FAIL**: watchdog suite (20 PASS / 26 FAIL) + two ECM source fingerprint false negatives after AUTOREMOVE |
| CI #125–#126 | **FAIL before PREPARE_ONLY**: `git diff --check` found an extra blank line at EOF in the handoff; fixed by `e31ca88` |
| CI #127 Static checks + PREPARE_ONLY on `faa82e24` | **PASS**: source preflight and ordered ECM patch queue passed |
| CI #127 full-build | **CANCELLED / interrupted**: runner shutdown, exit code 143 during `./build.sh`; no compile or final verifier result |
| CI #128–#129 | **CANCELLED before jobs were created** |
| Watchdog absolute-stub dispatch (`f372d519`, `0d2aeadb`) | Static checks **PASS** in #127; watchdog runtime suite **NOT CI-VALIDATED** |
| ECM AUTOREMOVE fallback and explicit config guard (`e7846a1`, `49d3579`) | **NOT CI-VALIDATED** on current code/test HEAD |
| New completed full CI on exact HEAD `49d3579` | **NO RUN / no status found** |
| Runtime module load on RD03v2 | **NOT TESTED** |
| Hardware Dual-WAN/NSS failover and stress | **NOT TESTED** |

### Исторические результаты preflight #106–#108

Старые workflow #106–#108 ниже приведены для истории source-preflight и callback guards. Они не заменяют актуальный baseline в таблице выше и не означают, что исправления после CI #124 уже перепроверены.

### Подтверждение ECM source preflight

Workflow [#106](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729319036)
на функциональной ревизии `006e14a5d0348528a021943b1fd595cc233451db`
прошёл Static и PREPARE_ONLY. Лог шага ECM preflight подтверждает:

- 9 уникальных file sections и 19 корректных unified-diff hunks;
- загрузку и SHA-256 проверку точного архива QSDK 14.0
  (`7894b769eeb64f1c44fde547a107a8b866997590`);
- успешный `git apply --check` к чистому pinned source;
- успешное применение patch 9002 после всех 31 закреплённых feed patches,
  включая RD03v2 patch 9001;
- совпадение lock/counter операций для IPv4/IPv6 и шести packet-hook чтений;
- атомарный snapshot pending bits под RTNL, закрытие frontend gates до
  `synchronize_net()` и DB defunct walk;
- порядок FIB notifier registration, init unwind, normal exit и drain worker
  перед frontend teardown.

Это подтверждает **применимость и статически проверенную последовательность
кода**, но не компиляцию C и не runtime-корректность на роутере.

### Полная сборка

Workflow [#107](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729849069)
запущен commit `eba9d0231c6b85842f540bb0091c3d81ac76bb0a`: Static и PREPARE_ONLY
успешны, job `Full signed-image build and verify-v2` находится в работе.
Workflow [#108](https://github.com/ilimdarilimdar/openwrt-xiaomi-ax3000t-rd03v2/actions/runs/43729952928)
поставлен в очередь из-за второго test-only commit `a0e72ce`; он проверяет
более строгий callback guard при той же функциональной firmware revision.
Два запуска не являются двумя независимыми проверками архитектуры.

Оба full-build workflow используют временный P-256 signing key и URL пакетов
`example.invalid`, загружают только build logs и не публикуют пользовательский
release. Не устанавливать такой CI-образ на основной или тестовый роутер.

### Ограничения CI и конфигурации

PREPARE_ONLY успешно собирает pinned sources/feeds и генерирует итоговую
конфигурацию, однако Kconfig-циклы Qt5 GUI, fwknopd и squeezelite-custom
требуют отдельной классификации по логам. NSS dependency guard patch 0014
ограничивает зависимость LuCI NSS на целевой IPQ50xx конфигурации до
`nss-tools-dwmac`; workflow проверяет этот guard статически. Не удалять
предупреждения ради формально чистого отчёта.

## 3. Этап A — проверка исходников и конфигурации

Перед каждым прогоном записать:

- полный SHA рабочего коммита;
- upstream commit из `upstream.lock`;
- все feed commits из `feeds.lock`;
- версию/дату ECM и kernel line;
- список tree patches и feed overlay;
- параметры сборки: TAG, JOBS, TREE, RD03V2_WS;
- версию workflow и номер запуска.

Проверить:

1. Target ровно один: `xiaomi_mi-router-ax3000t-v2`.
2. Профиль памяти/радио соответствует именно 256 MiB RD03v2.
3. Все обязательные NSS/ath11k symbols сохранились после `make defconfig`.
4. `mwan3`, `luci-app-mwan3`, `iptables-nft`, `ip6tables-nft`, `xtables-nft`, `ipset` и расширения conntrack/ipopt выбраны.
5. Не произошло незаметной подмены nft backend на legacy xtables.
6. Пакеты AWG/WireGuard/SQM имеют ожидаемое состояние (встроены в образ или собираются в отдельный репозиторий) и не смешиваются с утверждением об NSS offload.
7. Нет приватного ключа, паролей, конфигураций VPN, реальных публичных IP или иных секретов в Git.
8. Локальный тест `tools/test-install-v2-signing-key.sh` проходит; статический guard подтверждает RD03v2-only зависимость `luci-app-nss`.

**Критерий PASS:** все ожидаемые символы присутствуют в итоговом `.config`, feeds стоят на закреплённых SHA, overlays/patches применены без обхода ошибок, а результаты сохранены.

## 4. Этап B — PREPARE_ONLY

Проверить артефакт подготовки, а не только зелёный статус GitHub Actions:

- `feeds-update.log`;
- `feeds-install.log`;
- `defconfig.log`;
- `config.final.txt`;
- `diffconfig.txt`;
- `tmp/.config-package.in` — полный сгенерированный граф Kconfig-зависимостей.

Обязательно разобрать:
- неразрешённые зависимости пакетов;
- сообщения об отсутствующих пакетах;
- Kconfig recursive dependency;
- предупреждения о переопределении choice symbols;
- feed clone/fetch warnings;
- несовпадения pinned commit.

Предупреждение можно классифицировать как безвредное только после проверки его источника и подтверждения итогового состояния. Не удалять диагностику из логов для получения «чистого» отчёта.

**Критерий PASS:** источники и feeds получены с ожидаемых ревизий, defconfig завершился с кодом 0, целевые symbols сохранены, все существенные предупреждения классифицированы.

## 5. Этап C — полная сборка

Для текущего CI-run фиксировать отдельно:

1. подготовку/генерацию временного signing key;
2. `make download`;
3. `make -jN BUILD_LOG=1`;
4. package indexing;
5. создание Wi-Fi initramfs installer pair;
6. `tools/verify-v2.sh --tree`;
7. создание и загрузку логов.

При ошибке определить точный первый провалившийся шаг. Не считать тайм-аут runner, нехватку диска или памяти ошибкой исходников, пока это не подтверждено логом.

**Критерий PASS:** сборка завершилась с кодом 0, все проверки `verify-v2.sh` имеют PASS, отсутствуют необъяснённые FAIL, а kernel/modules/image относятся к одному и тому же pinned build tree.

**Примечание:** успешный CI-build с временным ключом и `example.invalid` подтверждает компиляцию и проверки, но не пригодность образа к установке.

## 6. Этап D — выпускопригодность артефактов

До создания реального релиза отдельно выполнить и зафиксировать:

- соответствие имени/профиля образа точной ревизии RD03v2;
- проверку factory/initramfs и sysupgrade типов по назначению;
- проверку содержимого rootfs/пакетов в самом образе, а не только staging directory;
- SHA-256 каждого артефакта;
- корректность package manifest и vermagic у kernel modules;
- наличие правильного публичного ключа и доступность подписанного package repository;
- соответствие URL репозитория фактическому опубликованному репозиторию;
- отсутствие временного signing key и `example.invalid` в релизной конфигурации;
- release notes с явным списком NOT TESTED.

Никогда не переиспользовать временный CI-ключ как ключ стабильного обновления. Смена ключей подписи должна быть отдельной контролируемой процедурой.

## 7. Этап E — подготовка аппаратного стенда

Первое устройство для испытаний — только вторичный AX3000T RD03v2, не основной маршрутизатор дома.

Перед установкой:
- визуально подтвердить аппаратную ревизию RD03v2;
- сверить образ и SHA-256;
- сохранить текущую конфигурацию и доступные резервные копии;
- иметь проверенный путь восстановления к рабочей прошивке;
- обеспечить проводное подключение и локальный доступ;
- не полагаться на Wi-Fi для первичной установки/восстановления;
- зафиксировать исходное состояние и версии;
- иметь независимый доступ к питанию и не прерывать запись NAND.

Установка выполняется только по официальной процедуре проекта для точной ревизии. Не использовать общий sysupgrade/WebUI путь от другой аппаратной ревизии. Не запускать команды записи во flash до прохождения этапов A–D и проверки процедуры восстановления.

## 8. Этап F — первичная загрузка и базовая функциональность

После успешной установки на стендовое устройство:

- подтвердить, что система загрузилась и не уходит в reboot loop;
- проверить наличие всех LAN-портов и фактическую DSA-разметку;
- проверить оба диапазона Wi-Fi;
- проверить доступ к LuCI и SSH;
- проверить время, DNS, DHCP и firewall4;
- записать kernel log, system log, uptime, свободную RAM и состояние NAND;
- перезагрузить устройство штатным способом и повторить базовые проверки.

Не считать доступность LuCI доказательством исправности сетевого datapath.

**Критерий PASS:** штатная загрузка повторяется, LAN/Wi-Fi работают, отсутствуют kernel oops/panic и необъяснимые перезапуски, доступ к восстановлению сохраняется.

## 9. Этап G — WAN1 и WAN2 по отдельности

До включения mwan3 проверить каждый WAN независимо.

Для каждого канала записать:
- физический порт и DSA netdev;
- имя logical interface netifd;
- IPv4/IPv6 адреса и тип получения;
- gateway, DNS, MTU и инкапсуляцию;
- таблицу маршрутизации и default route;
- ping/RTT/loss до нескольких контрольных адресов;
- стабильный TCP download/upload;
- CPU, RAM и NSS/ECM counters, если соответствующие интерфейсы доступны.

Тестировать одинаковым клиентом, сервером и интервалом. Сначала снять baseline без балансировки. Отдельно записать поведение, если IPv6 у провайдера отсутствует.

**Критерий PASS:** WAN1 и WAN2 отдельно обеспечивают маршрутизацию и DNS, интерфейс не флапает, default route предсказуем, значения измерений сохранены.

## 10. Этап H — firewall4 и mwan3

Начать только с failover. Балансировку не добавлять до успешной проверки.

Проверить:
1. `iptables --version` и `ip6tables --version` показывают `nf_tables`.
2. firewall4 остаётся активен.
3. После запуска mwan3 создаются ожидаемые mangle chains и ipsets.
4. `mwan3 status` показывает правильные logical interfaces.
5. `ip -4 rule`, `ip -6 rule` и все routing tables содержат ожидаемую policy routing конфигурацию.
6. Повторные ifdown/ifup и restart mwan3 не ломают firewall4 ruleset.
7. Failover WAN1 → WAN2 и WAN2 → WAN1 реально проверяется отключением физического линка и отдельным тестом потери upstream reachability.

Для каждого перехода измерить:
- время обнаружения отказа;
- время восстановления новых соединений;
- какой WAN обслуживает новые потоки;
- судьбу уже открытых TCP/UDP сессий;
- наличие conntrack/NAT stale state;
- изменения routes/rules/fwmarks;
- kernel log и ECM/NSS counters.

Не обещать сохранение существующей NAT-сессии при смене WAN: смена публичного IP/пути обычно требует нового соединения.

**Критерий PASS:** новые соединения уходят через доступный uplink; после восстановления канала маршруты и policy rules возвращаются в ожидаемое состояние; firewall4 остаётся согласованным; нет зависших новых потоков или kernel errors.

## 11. Этап I — балансировка и суммарная пропускная способность

Проводить после failover.

- Запустить несколько независимых TCP-потоков одновременно.
- Для каждого потока записать исходный WAN и итоговый WAN по счетчикам.
- Сравнить суммарную скорость с отдельными baseline WAN1 и WAN2.
- Проверить, что один TCP flow не интерпретируется как bonding.
- Отдельно измерить CPU, RAM, NSS/ECM counters и latency.
- Повторить тест с длительной передачей и параллельным игровым/интерактивным трафиком.

**Критерий PASS:** несколько независимых потоков действительно распределяются между WAN по заданной политике, счётчики подтверждают распределение, суммарная скорость и нагрузка документированы.

## 12. Этап J — ECM/NSS и policy-rule changes

Это отдельный критический этап. Наличие NSS-пакетов в образе не является подтверждением offload.

До включения v2 ECM patch:
- взять исходный ECM archive из pinned Makefile;
- проверить SHA-256;
- сопоставить API и lifecycle с Linux 6.18;
- проверить notifier callback, atomic context, workqueue, register/unregister и teardown;
- проверить patch dry-run, затем compile package.

На стенде сравнить stock ECM и patched ECM:
- изменение policy rules;
- маршруты-first и rules-first порядок восстановления;
- IPv4 routed/NAT;
- routed IPv6 только при наличии рабочего IPv6;
- PPPoE/DHCP/static WAN по доступной топологии;
- restart mwan3;
- cable pull и восстановление;
- повторные изменения правил под трафиком.

Снимать:
- kernel logs;
- ECM/NSS counters;
- throughput и CPU;
- число активных flows;
- потери/паузы трафика;
- сообщения notifier registration и ошибки unregister/workqueue.

**Критерий PASS:** патч компилируется для точного kernel/feed pin, notifier регистрируется и корректно снимается, нет deadlock/oops/warnings, stale accelerated flows не оставляют трафик на ошибочном WAN, slow-path/re-acceleration измерены.

## 13. Этап K — AmneziaWG/WireGuard и SQM

Проверять после базового WAN/mwan3/NSS:

- handshake и endpoint reachability;
- DNS внутри и снаружи туннеля согласно политике;
- split/full tunnel;
- поведение при failover;
- MTU/MSS и fragmentation;
- throughput и CPU;
- отдельные NSS/ECM counters для обычного NAT и туннеля;
- работа SQM на выбранном интерфейсе и влияние на latency.

Не объявлять AWG-трафик NSS-ускоренным без измеренного подтверждения. VPN throughput может быть CPU-bound.

## 14. Этап L — стабильность и восстановление

Минимум:
- повторные переключения WAN в обе стороны;
- повторные restart mwan3;
- длительная передача;
- одновременная нагрузка Wi-Fi и Ethernet;
- перезагрузка;
- проверка памяти и системного журнала;
- проверка recovery procedure на стендовом устройстве.

Зафиксировать продолжительность теста, условия окружающей среды и все неожиданные reboot/thermal/memory события. Длительность теста должна быть названа в отчёте, а не обозначена общим словом «долго».

**Критерий PASS:** за установленный период нет необъяснимого reboot, kernel panic/oops, утечки памяти, необратимой потери WAN/LAN/Wi-Fi или невозможности recovery.

## 15. Warface / low-latency сценарий

Для игрового трафика приоритет — стабильность, а не максимальный throughput.

Сравнить на одинаковом клиенте и одинаковой последовательности:
- stock baseline;
- WAN1 only;
- WAN2 only;
- failover profile;
- balanced profile, если он нужен;
- VPN profile, отдельно.

Для каждого режима записать median, p95/p99 RTT, jitter, packet loss, spikes, загрузку CPU и реальные route/interface counters. Измерять и idle, и под нагрузкой (bufferbloat). Не переключать WAN на каждый одиночный скачок ping: использовать hysteresis/hold-down и проверять flapping.

## 16. Шаблон отчёта тестового прогона

```text
Run ID:
Date/time/timezone:
Device hardware revision:
Firmware tag:
Git commit SHA:
OpenWrt/NSS upstream SHA:
NSS feed SHA:
ECM source SHA:
Kernel:
Feed pins:
Build workflow/run:
Image SHA-256:
Test stage:
WAN topology:
WAN encapsulation/MTU:
IPv4/IPv6:
NSS/ECM state:
mwan3 policy:
Test duration:

Expected result:
Actual result:
PASS / FAIL / NOT TESTED / INCONCLUSIVE:
RTT median / p95 / p99:
Jitter:
Packet loss:
Throughput down/up:
CPU / RAM:
NSS/ECM counters:
Relevant ip rule / route snapshots:
Kernel/system log:
Unexpected reboot or instability:
Artifacts/logs:
Recovery result:
Next action:
```

Перед публикацией удалить из логов публичные IP, ключи, пароли, MAC-адреса и прочие идентификаторы, если они не нужны для воспроизведения.

## 17. Gate перед публичным релизом

Релиз запрещён, пока не выполнено всё необходимое:

- build и `verify-v2.sh` — PASS;
- образ проверен по содержимому, target и SHA-256;
- постоянный ключ подписи надёжно управляется владельцем;
- package repository опубликован и проверен;
- installer/recovery процедура соответствует RD03v2;
- первичная загрузка на стендовом RD03v2 — PASS;
- WAN1/WAN2 отдельно — PASS;
- firewall4/mwan3 failover — PASS;
- NSS/ECM фактическое ускорение — измерено;
- ECM rule-change tests — PASS либо ограничение явно задокументировано;
- AmneziaWG/SQM — проверены или явно помечены NOT TESTED;
- release notes и manifest не скрывают ограничений.

До прохождения этого gate образ остаётся экспериментальной сборкой. Основной домашний маршрутизатор не использовать в качестве первого тестового устройства.
