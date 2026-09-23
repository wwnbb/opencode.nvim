# Ход миграции на OpenCode 2.0.11

Ниже сохранён отчёт о миграции на 21 сентября 2026 (локальное время).
Функциональность todo tools, persistent store и dock удалена 23 сентября 2026;
упоминания в исходных планах и сохранённых снимках относятся к прежнему состоянию.
Исходный HEAD — `58fcf3c`;
исходные незакоммиченные исправления сохранены. **Согласованный объём миграции выполнен.**
Итоговая сверка семи планов и границы доказательств — [FINAL-VALIDATION.md](FINAL-VALIDATION.md).
Перенос старой server history исключён пользователем; текущая v2 history проверена.

## Реализовано

- A/B: HTTP/SSE `/api`, version probe, Basic auth, IPv6, location, sessions,
  каталоги и страницы истории. Реальный CLI подтвердил port=0, default ephemeral
  password, restart/stop собственного процесса и reconnect к внешнему.
  Внешний процесс не завершается при disconnect. Сгенерированный пароль не
  сохраняется в пользовательскую конфигурацию и debug output.
- C: последовательные agent → model → prompt, outbox и admission отдельно от
  исполнения. Native DTO сохраняется в `_v2`; stream/history используют одну
  проекцию. Полная загрузка обходит opaque cursors в обе стороны; частичная
  страница не удаляет отсутствующие данные. Поздний HTTP не заменяет свежий SSE.
  Selection принадлежит сессии; native variant `default` нормализуется.
- D: native permissions/forms, owning-session routing, typed values/drafts,
  conditional/external fields, validation/recovery. Bundled tools — Effect Plugin
  2.0.11 и review RPC protocol 1. Native policy проверяется до чтения/rg/review;
  `allow` инструмента не принимает diff. Проверены ask/apply, deny, interruption,
  pending recovery и mixed multi-file review с настоящим native diff.
- E: integrations/key/OAuth/command и отдельные credentials, MCP status/mutations,
  команды, native skill attachments, fork/diff/revert/compact.
  Preferences format 2 сохраняет `.v1.bak`, недоступные favorites и неизвестные
  настройки; legacy aliases преобразуются только однозначно.
- F: установщик сохраняет пользовательский JSONC/commands, убирает только
  идентифицированные неизменённые v1 tools/load_skills. Есть изолированный CLI/
  Neovim harness и attached UI снимки. UI/runtime матрица проверена с ограничениями
  провайдера и источников данных, явно перечисленными ниже.

## Сохранённые доказательства

Все пути ниже — в `tests/fixtures/v2/`.

| Каталог | Проверка |
|---|---|
| runtime | CLI/info/auth, session/catalogs, prompt/SSE/history, duplicate prompt ID |
| interactions | Native permission/form round-trip и owning-session routing |
| integration | Изолированные fake key/OAuth code/auto/command, expiry/cancel/accounts |
| commands | Native command catalog/204 и реальный ответ модели |
| attachments | UTF-8 file URI, inline PNG, agent mention |
| input-attachments | Visual selection 2–3 и PNG через настоящий input/C-g, native history и ответ MiMo |
| session-ops | Fork, explicit diff range, stage/clear/commit и compaction |
| lifecycle | Owned/external process ownership, ephemeral auth |
| review | Native ask/review/apply, interruption/late reply и deny |
| review-reconnect | Потеря SSE/local review state → RPC recovery → accept |
| review-matrix | 8 entries: add/update/delete/move, mixed reject/manual/BOM/EOL |
| server-review | Применение сервером, запрет local manual, idempotent повтор RPC |
| clean-install | Чистая установка и реальная загрузка актуального plugin |
| rg | Реальный subprocess: matches/empty/error, SSE reconnect, interrupt и queued input cancel |
| queue | Input C-g, badge, palette cancellation, C-c сохраняет inbox, reconnect и explicit steer через MiMo |
| selection | C-a/C-e/C-t, model palette, Plan/Build с MiMo, два native variants без генерации на другой модели |
| auth-ui | Реальные palette/setup/inputsecret, OAuth URL/code, cancel/expiry, activate/delete account, сохранён env account |
| mcp-auth-ui | Native needs_auth после локального HTTP 401, info popup и связанный integration menu |
| compatibility-missing / compatibility-obsolete | Actual CLI 2.0.11 без plugin и с тестовым protocol 0; отдельный simulated 1.9.0 info через реальный TCP отклонён до SSE/spawn |
| cold-history | Новый Neovim: complete/error/interrupted rg из native HTTP DTO, без сервера |
| session-scope | Три Git projects одновременно, адресат permission, late HTTP после delete |
| form-ui | Actual keymaps: все типы полей, conditional draft, local/server validation, второй curl-клиент, once/always/reject |
| first-toggle | Первый toggle запускает сервер, i фокусирует input; restart/stop/external ownership |
| reopened-navigation | Новый Neovim: gd/BS для двух native children, delete tree при поздних HTTP callbacks |
| reopened-review | Новый Neovim/сервер: final mixed review, readonly inline diff, disk bytes не изменены |
| ui | N keymap, /skill и real Nui chat |
| text-reconnect | Разрыв ответа из 40 строк: live == HTTP == cold render |
| ui-baseline | Общая fixture before/after и renderer timings |
| subagent | Исходная отрицательная проверка ограничения Zen |
| subagents-deepseek | Две успешные background tasks на Go/DeepSeek V4 Flash, overlap, shell, spinner, gd/BS, SSE reconnect и обе completion notifications |
| reopened-background | Новый сервер/Neovim: исходная база успешных DeepSeek children, правильный idle и delete tree при поздних callbacks |
| form-history / reopened-form | Native question от MiMo, keyboard answer, durable readonly summary в новом Neovim |
| stream-layout | 160 строк, terminal 120×40 → 80×30 → 140×44, три layout, light/dark, input draft/focus/cursor и live == cold |

В mixed review `dv` открывает actual/proposed panes. `<C-a>` при disconnect не
сохраняет ручной буфер; после reconnect он сохраняется как resolved. `<C-x>`
отклоняет другой файл. Проверены final bytes и metadata.status=partial.
Закрытие diff сохраняет actual window и ширину чата. Native RPC проверяет JSON
до сериализации: optional JS `undefined` удаляется из metadata/records.

Text reconnect: модель вернула все ROW01–ROW40 в чат без tools, SSE оборван на
первой text delta. `_v2`, parts и buffer после recovery совпали с полной HTTP
историей; `auto_scroll=false` сохранился. Отдельный deterministic test объединяет
400 delta в одно обновление блока через существующий 16 ms scheduler.

Native forms keyboard run сохраняет integer/number zero, boolean false, distinct
option values, multiselect и hidden defaults. Conditional draft переживает
скрытие/возврат. Сервер отклонил regex value, input сохранил draft и повторная
отправка прошла. Ответ второго curl-клиента во время SSE gap восстановился из
form detail. External URL dispatch перехвачен тестом (браузер не открывался),
локальный submit заблокирован, server cancellation отобразился. Once/reject
не сохраняют правило; always сохраняет только явно заданные save patterns.

Input attachments: visual selection файла с Unicode и пробелами сохраняет только
строки 2–3; один C-g отправляет selection и PNG. Личный clipboard не читается:
изолированный osascript shim выдаёт созданную 2×2 PNG, дальше работает обычный
macOS clipboard reader/input. Native history содержит точные text/base64 bytes,
MiMo ответила INPUT_ATTACHMENT_READY. Это не проверка содержимого системного clipboard.

`reopen_v2.py` не отправляет prompt. Для navigation ранее записанные native
parent/child DTO восстановлены через public experimental session import: исходный
capture удалил эти тестовые сессии при завершении. Это проверка UI/history и
native cascade deletion, не новое успешное выполнение subagents. Обнаруженные
ошибки исправлены: пустой assistant с provider error теперь отображается;
удалённые children не сохраняют execution locks/pending interactions. Review
загружен из исходной тестовой server database новым Neovim; семь final results
(move объединяет две pending choices) доступны readonly, включая destination.
Actual linegrid выявил ещё и viewport дефект: после длинного parent короткий child
открывался с topline на последней пустой строке. При смене session viewport
сбрасывается, auto-scroll выравнивает низ окна; новый screenshot показывает
историю и provider error. Reconnect в той же session не сбрасывает viewport.

UI снимки получены из настоящего Neovim linegrid 120×40 (Neovim
0.12.0-dev-2149+ga60d5f863e-Homebrew, Menlo 16). PNG не рисует курсор; focus
проверяется API. Vertical/horizontal/float/input общей fixture побитово совпали
с baseline HEAD. Этот baseline — committed UI, без исходного dirty patch.
30 render вызовов после 5 warmups на 80 сообщениях: median 1.039 → 1.013 ms,
p95 1.312 → 1.206 ms. Это узкий тест Nui renderer, не benchmark сети/адаптера.

## Проверки и воспроизведение

Полный `./tests/run.sh` после JSON/native diff/layout исправлений, новых
58 wire tests, ожидания начальных каталогов, historical error, delete-tree cleanup и move destination
прошёл unit/checks/integration/smoke/tools: 22 Bun tests,
95 assertions. Чистая установка и реальная загрузка актуального plugin прошли.
Viewport исправление прошло targeted integration, native UI и полный suite.
Queue recovery и UI прошли реальный сервер и полный suite; 8 новых regression
проверяют inbox/history races, поздние terminal events и unknown outcome.
Выбор и auth UI прошли actual attached Neovim. Новый полный suite после
исправлений draft variant и popup width также прошёл.
Compatibility runtime и полный suite после проверки capabilities на первой
сессии прошли. Старый backend в этом сценарии — HTTP fixture, не CLI v1.

Wire matrix проверяет HTTP method/URL, escaping, JSON body, success envelope,
однократный callback и HTTP 401 для каждой операции; пути сверяются с pinned
contract inventory. Semantic facade construction и domain errors проверяются
отдельными send/auth/form/review/history tests и реальными fixtures.

`tests/runtime/capture_v2.py` изолирует XDG config/data/state/cache, TMPDIR,
OPENCODE_CONFIG_DIR и OPENCODE_TEST_HOME. Личные credentials не наследуются.
Основные проверки использовали `opencode/mimo-v2.5-free`. По последующему
указанию пользователя фоновые subagents проверены через OpenCode Go: сначала
`glm-5.3-flash`, затем `deepseek-v4-flash`. Последний final fixture — DeepSeek.
Пользователь явно предоставил тестовый ключ после запроса разрешения; он передавался
только через environment выбранного provider. Fixtures, logs и тестовые профили
проверены на отсутствие этого ключа. Личная база открывалась только read-only.
Пример (каталог output должен быть новым):

```sh
python3 tests/runtime/capture_v2.py \
  --cli /path/to/exact-2.0.11/opencode \
  --output /tmp/new-capture-directory \
  --server-plugin "$PWD/opencode_nvim/plugins/opencode-nvim" \
  --model opencode/mimo-v2.5-free --nvim-review-matrix --attached-ui
```

Для attached UI нужны Python msgpack/Pillow и macOS Menlo. Без флага — headless.
Другие флаги: `--nvim-smoke`, `--nvim-interactions`, `--nvim-form-ui`, `--nvim-input-attachments`, `--auth`, `--nvim-review`,
`--nvim-server-review`, `--nvim-ui`, `--nvim-reconnect`,
`--nvim-lifecycle`, `--nvim-rg`, `--nvim-queue`, `--nvim-selection`, `--nvim-auth-ui`, `--nvim-session-scope`, `--attachments`, `--commands`, `--session-ops`, `--mcp`.
`--install-tools` устанавливает plugin в чистый профиль. В sandbox транспортным
тестам нужен loopback TCP; EPERM без этого доступа не считается полным прогоном.

## Итог E01–E22

| ID | Статус / оставшаяся проверка |
|---|---|
| E01 | Первый toggle → owned startup → i/input прошёл, дополнительный процесс не создаётся |
| E02 | Реальный ответ/live/history проверены |
| E03 | C-a/C-e/C-t и palette прошли; Plan/Build генерировали через MiMo; два variants другой catalog model подтверждены native settings без generation (у MiMo variants нет) |
| E04 | File/image/agent round-trip, skill UI, visual selection и PNG input/C-g прошли; источник clipboard изолирован shim |
| E05–E06 | Busy input/C-g, queued badge, palette cancel, C-c сохраняет очередь, reconnect и explicit steer прошли на blocked rg; отменённые inputs не исполнились |
| E07–E08 | Native typed keyboard UI, conditional drafts, server/local validation, второй клиент при SSE gap и once/always/reject прошли; external link dispatch/cancel проверен |
| E09–E10 | Edit/mixed patch/manual/BOM/EOL проверены; server-apply и idempotent повтор проверены |
| E11 | Реальный rg success/empty/error, running subprocess cancel и UI проверены |
| E12 | Go/DeepSeek: два background children с одинаковым названием, одновременное исполнение, shell success, spinner, gd/BS, reconnect и обе parent notifications; cold reopen также прошёл |
| E13 | Удалено 23 сентября 2026 вместе с todo tools и dock |
| E14 | Text/review/manual diff/running rg reconnect; 160-line resize/theme/layout run сохранил cursor, focus, draft и auto-scroll; live == cold |
| E15 | Три directories одновременно: send, selection, catalog, history, permission и смена вкладок прошли runtime |
| E16 | Fork/diff/revert/compact проверены |
| E17 | Fake integration/accounts lifecycle и actual UI key/OAuth code/cancel/expired/activate/delete прошли; ввод secret не попадает в buffers |
| E18 | MCP connect/disconnect и native needs_auth от локального HTTP 401 прошли; info и a:auth открывают связанный OAuth method |
| E19 | Owned restart, external reconnect, location reload проверены |
| E20 | Real root + 2 children deletion при удержанных HTTP callbacks прошёл; locks/interactions и tokens очищаются |
| E21 | Fresh Neovim восстановил rg, child errors и success, mixed readonly review/inline diff и завершённый native question с выбранным ответом |
| E22 | Real transport отклоняет simulated incompatible info до SSE/spawn; real CLI без plugin / с protocol 0 показывает installer/version instruction сразу в первой session |

Перенос старой server history и migration status (историческая часть R9)
исключены пользователем 21 сентября: «скипнем перенос старой истории это вообще не нужно».
Fork/revert часть R9 уже проверена. Старая CLI лишь скачана с проверкой integrity;
изолированные --version/debug paths/--help выполнены, импорт/миграция не запускались.

Background tasks, narrow/resize/theme/focus во время streaming и финальная
сверка семи планов завершены. Критерии отмечены в исходных документах; ссылки
на доказательства собраны в FINAL-VALIDATION.md.

## Подтверждённые ограничения

- Plugin.Context 2.0.11 не предоставляет permission.create. Lua вызывает native
  HTTP endpoint для exact policy RPC request; plugin ждёт native evaluate hook
  или asked/replied. RPC boolean allow не обходит policy.
- MCP catalog и public ctx.tool.list после reload не раскрывают MCP tool definitions.
  Палитра сообщает это явно; status/auth доступны. Runtime LSP отсутствует.
- File URI относится к server filesystem; clipboard image — inline data. Native
  TUI mention offsets — display cells. Неопределённый range опускается, вложение
  сохраняется. Прямой TLS не поддерживается.
- Внешний сервер по умолчанию применяет review сам. Local diff/manual требуют
  `server.shared_filesystem=true`. Собственный процесс разделяет FS автоматически.
  SSH tunnel сам по себе не означает общую файловую систему.
- Zen отклонил model requests двух explore children: “OpenCode’s free tier can
  only be used from within OpenCode”. Ограничение не обходилось. После явного
  выбора Go пользователем успешные фоновые children подтверждены другим provider.
- Откат Lua checkout не откатывает server database migration. Сохраняются старый
  checkout, конфигурация и installer backups; восстановление базы отдельно.

В проверке трёх новых locations обнаружен ранний пустой model catalog во время
загрузки plugins. Send теперь до admission ждёт такие каталоги до 5 s, сохраняя
исходные session/directory/selection. Unit regression, real три-project
сценарий и новый полный suite прошли.

Queue runtime выявил, что complete history не включает inbox: reconnect удалял
queued message из чата. Recovery теперь объединяет history с pending payloads,
принимает terminal SSE раньше HTTP и учитывает delivery.changed. Отсутствие
записи в двух неатомарных снимках не объявляется cancellation: показывается
unknown delivery без автоматического повторного POST. UI cancellation имеет
отдельную palette command и не останавливает исполняющийся rg.

Selection проверка выявила перенос ещё не отправленного variant между разными
моделями: выбор model теперь сбрасывает variant предыдущей модели. Auth screenshot
выявил общий chat width внутри меньшего setup popup: локальная форма передаёт
фактическую ширину, переносит длинные options и ставит cursor на их реальные строки.
Системный браузер не открывался: URL dispatch перехвачен тестом. Все auth данные —
публичные sentinels отдельного fixture plugin, личные credentials не читались.

Compatibility run выявил, что capability recovery слушал только session.selected,
но создание первой session посылает session_change. Проверка подписана на общую
границу смены session и защищена от старого RPC с non-object output. Missing/old
plugin не объявляется доступным; native history endpoint остаётся читаемым.

Финальный полный suite после исправлений completed question, input resize и
child activity recovery: **307 Lua tests, 22 Bun tests / 95 assertions**, failures 0.
`git diff --check` прошёл. Последний runtime DeepSeek дождался обеих completion
notifications и idle родителя; затем исходная база открыта новым процессом без
ключа и без новых model requests. При завершении удалено только тестовое дерево.

Финальные UI исправления: completed native question отображает durable answers
из tool metadata, не создавая новую интерактивную форму. Input пересчитывает обе
поверхности при resize, поэтому info bar остаётся видимым. Native active snapshot
восстанавливает статусы известных children в обоих stores, а более новое SSE
побеждает поздний HTTP. Это устраняет вечный spinner после cold reopen.
