# AGmind Mock Infrastructure

> Phase 13 / TEST-08. Эта папка содержит **PATH-override моки** — bash-stubs,
> которые перехватывают вызовы системных команд во время тестов. Реальные
> `docker`, `curl`, `ssh` и т.п. остаются нетронутыми; mock-копии подсовываются
> через `PATH` prefix.

## Зачем

Hermetic тестирование. Никаких реальных:

- сетевых вызовов (`curl`, `host`, `nslookup`, `ping`, `scp`, `ssh`)
- демонов (`docker`, `systemctl`)
- железо-запросов (`nvidia-smi`, `df`, `free`, `uname`)
- privilege-операций (`iptables`, `ufw`, `sysctl`)
- пакетных менеджеров (`apt-get`, `apt-mark`)
- UI (`whiptail`, `xdg-open`)

Любой тест (`tests/unit/*.sh`, `tests/golden/run.sh`, `tests/integration/*.sh`)
prepend'ает `tests/mocks/` в `PATH`:

```bash
PATH="${REPO_ROOT}/tests/mocks:${PATH}" bash my_test.sh
```

И настоящая система не дёргается.

## Passthrough-by-default Contract

Каждый mock придерживается **passthrough-by-default**: если фикстура задана
через env var `MOCK_<BIN>_FIXTURE=<file>` (или `MOCK_<BIN>_RESPONSE`) — mock
возвращает её детерминированный output; иначе делает `exec` реального binary
(или, в простых случаях, exit 0 без побочных эффектов).

Минимальный шаблон:

```bash
#!/usr/bin/env bash
# tests/mocks/example
if [[ -n "${MOCK_EXAMPLE_FIXTURE:-}" && -f "$MOCK_EXAMPLE_FIXTURE" ]]; then
    cat "$MOCK_EXAMPLE_FIXTURE"
    exit "${MOCK_EXAMPLE_EXIT:-0}"
fi
exec /usr/bin/example "$@"
```

Это позволяет thread-safe coexistence: тест, который **не** заинтересован в
mock'ании конкретной команды, не должен задавать env — реальный bin
выполнится. Тесты с требованием детерминизма ставят fixture file.

Существующие моки используют два варианта этого контракта:

- **Env-keyed switch** (см. `nvidia-smi`, `docker`) — `MOCK_<BIN>_FIXTURE`
  выбирает один из named-сценариев (`dgx_spark`, `driver_590`, `no_gpu`...).
- **Single-response stub** (см. `curl`) — `MOCK_<BIN>_RESPONSE` задаёт raw
  body, `MOCK_<BIN>_EXIT` — exit code. Чаще используется для one-off fixtures.

Опциональный shared helper `tests/mocks/_passthrough` доступен (см. ниже) для
шорткат-формулировки **нового** mock'а; existing mocks работают как есть
(opt-in, не refactor).

## Inventory

Все mocks executable (`100755`). Хранятся в репо с `core.fileMode=false`
(CLAUDE.md §8): после `git add` явно `git update-index --chmod=+x <file>`,
иначе exec-бит уйдёт в индекс как `100644` и PATH-lookup `bash` не найдёт
исполняемый файл. Total: **28 mocks** (verified 2026-05-17
`ls tests/mocks/ | wc -l` == 28).

| Mock                | Purpose / What it intercepts                                                  |
|---------------------|-------------------------------------------------------------------------------|
| `apt-get`           | Package installer — blocks real apt-get install/update during tests           |
| `apt-mark`          | `apt-mark hold/unhold` — used by NVIDIA driver pin tests                      |
| `avahi-resolve`     | mDNS resolver — checks `agmind-*.local` resolves during install               |
| `curl`              | HTTP client — fetches/posts; fixtures replay live API responses               |
| `df`                | Disk usage — `lib/doctor.sh` runs `df -BG /` for storage health gate          |
| `docker`            | Docker CLI — covers `docker ps/inspect/compose config/run/exec` (biggest mock by far) |
| `fping`             | Fast pinger — peer reachability check                                         |
| `free`              | Memory usage — `lib/doctor.sh` reads `free -g`                                |
| `host`              | DNS lookup — fallback when avahi unavailable                                  |
| `hostname`          | System hostname — read by config templates                                    |
| `ip`                | Network interfaces — `ip route`/`ip link` queries                             |
| `iptables`          | Firewall rules — peer NAT setup checks                                        |
| `lldpcli`           | LLDP neighbor discovery — QSFP peer link verification                         |
| `nslookup`          | DNS — same coverage gap as `host`, separate binary                            |
| `nvidia-smi`        | GPU info — `gpu_memory_utilization` budget calculation; UMA on Spark          |
| `ping`              | Basic reachability — host alive check                                         |
| `rotate_secrets.sh` | Internal rotate-secrets helper — tested in isolation                          |
| `scp`               | Remote copy — peer file deployment                                            |
| `sleep`             | Time delay — replaced with no-op for fast tests                               |
| `ss`                | Socket stats — `ss -ulnp` for mDNS daemon check                               |
| `ssh`               | Remote shell — peer command execution; never connects in tests                |
| `stat`              | File metadata — permissions / GID checks                                      |
| `sysctl`            | Kernel params — `vm.max_map_count` ES requirement                             |
| `systemctl`         | systemd — service start/stop/status                                           |
| `ufw`               | UFW firewall — rules check                                                    |
| `uname`             | OS info — arch check (`aarch64` required; x86_64 blocked since 2026-04-25)    |
| `whiptail`          | TUI prompts — wizard interactive UI; mocked to non-interactive default        |
| `xdg-open`          | URL opener — `agmind open` command end-of-install                             |

**Total: 28 mocks.** Любая правка inventory (добавление/удаление mock'а) обязана
синхронно править эту таблицу — `tests/lint/test_mocks_readme_lists_all.sh`
enforce-ит bi-directional consistency (mock без строки = FAIL, строка без mock'а =
FAIL).

## When to add a new mock

Добавлять если:

- Тест требует команду, которой ещё нет в `tests/mocks/`.
- Команда делает сетевой/демон/privilege вызов, ломающий hermetic property.
- Команда даёт варьируемый output на разных машинах (uname, hostname, df,
  free) — golden snapshots без mock'а будут drift'ить.

НЕ добавлять если:

- Команда тривиальная coreutils (`echo`, `cat`, `pwd`, `printf`) — она
  идентична на всех Linux.
- Команда уже есть, нужна другая fixture — расширь `MOCK_<BIN>_FIXTURE`
  switch в existing mock новым case'ом.

### Add procedure

1. Создать `tests/mocks/<bin>` (bash stub либо `. _passthrough` для shortcut).
2. `chmod +x tests/mocks/<bin>` локально (нужно чтобы тест мог запустить
   до `git add`).
3. `git add tests/mocks/<bin>`.
4. `git update-index --chmod=+x tests/mocks/<bin>` — обязательно, иначе
   индекс получит `100644` (CLAUDE.md §8 `core.fileMode=false`).
5. Verify: `git ls-files -s tests/mocks/<bin>` → `100755`.
6. Добавить строку в inventory table выше + обновить `**Total: N mocks.**`.
7. `bash tests/lint/test_mocks_readme_lists_all.sh` exits 0 (bi-directional
   gate) — pre-commit поймает drift при следующем `git commit`.

## Optional shared helper `_passthrough`

Если новый mock делает ровно standard passthrough-by-default — можно
сократить через source-ввод:

```bash
#!/usr/bin/env bash
# tests/mocks/example
. "$(dirname "$0")/_passthrough" /usr/bin/example "$@"
```

Helper читает env var `MOCK_<UPPER_BIN>_FIXTURE` (где `<UPPER_BIN>` =
basename real-binary'а в UPPER_SNAKE_CASE, `.`/`-` → `_`); если задано и
файл существует — `cat` его + exit из `MOCK_<UPPER_BIN>_EXIT` (default
`0`); иначе `exec` real binary.

Existing 28 mocks **НЕ переписаны** на helper — opt-in только для новых
(refactoring может изменить stdout newline-handling, ломая golden snapshots).
