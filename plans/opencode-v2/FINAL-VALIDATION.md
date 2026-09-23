# Итоговая проверка OpenCode 2.0.11

Это архивный отчёт о состоянии на 21 сентября 2026 года. Описанные здесь
todo tools, persistent store и dock удалены 23 сентября 2026 года.

Согласованный объём семи планов выполнен. Исходный HEAD `58fcf3c` и исходные
незакоммиченные изменения сохранены. Коммит, публикация и изменение личной
установки не выполнялись. Старую conversation history не импортировали:
пользователь явно исключил эту работу 21 сентября 2026.

## Сверка критериев

Пути fixtures ниже относительно `tests/fixtures/v2/`. Детальная матрица E01–E22,
объяснение runtime-сценариев и команды воспроизведения находятся в
[PROGRESS.md](PROGRESS.md).

| План | Проверенные критерии | Основные доказательства |
|---|---|---|
| 1. HTTP/lifecycle | Native envelopes/cursors/location/auth/version, процесс и callbacks, несколько directories | 57 HTTP operations + coverage case в `http_operation_matrix_v2_spec.lua`; `client_v2_spec.lua`, lifecycle/session tests; fixtures `runtime`, `lifecycle`, `first-toggle`, `session-scope`, `compatibility-*` |
| 2. Send | Selection до admission, prompt identity, queue/steer, attachments, unknown outcome и cancellation | `send_flow_spec.lua`, `inbox_recovery_v2_spec.lua`, `session_selection_v2_spec.lua`, attachment tests; `queue`, `selection`, `input-attachments`, `attachments` |
| 3. Sync/history | Одна HTTP/SSE projection, порядок и идентичность, partial/full snapshots, late HTTP, children/todo | Projection/reducer/pagination/render tests; `text-reconnect`, `stream-layout`, `subagents-deepseek`, `reopened-background`, `todos`, `session-ops` |
| 4. Permissions/forms | Session routing, native decisions, шесть типов полей, validation/drafts/conditional/external и второй клиент | Form state/recovery tests; `interactions`, `form-ui`, `form-history`, `reopened-form`, `session-scope` |
| 5. Tools/review | Реальный Effect plugin, native permission до файлов, mixed accept/reject/manual, interruption/idempotency, persistent TODO | 22 Bun tests / 95 assertions и Lua file-safety tests; `clean-install`, `review*`, `server-review`, `rg`, `reopened-review`, `todos` |
| 6. Catalog/auth/MCP | Location/invalidation, IDs/preferences backup, integrations/accounts, command/skill/MCP, fork/revert/compact | Catalog/auth/preferences/MCP/selection tests; `auth-ui`, `integration`, `mcp-auth-ui`, `commands`, `ui`, `session-ops` |
| 7. UI/E2E | Keyboard, widget summaries, streaming/recovery, focus/cursor, resize/theme, clean install, документация | Native attached UI fixtures перечислены в PROGRESS; `ui-baseline`, `stream-layout`, `reopened-*`, `compatibility-*`; полный suite |

Финальный `./tests/run.sh`: **307 Lua tests и 22 Bun tests**, без ошибок.
Проверены unit/checks/integration/smoke/tools; архитектурные ограничения не
ослаблены. `git diff --check` прошёл. Последние regression cases проверяют
durable question answers, сохранение input при resize и cold child activity
с защитой от более нового SSE.

## Последний модельный прогон

`opencode-go/deepseek-v4-flash`: два `general` children с одинаковым названием
`Small test`, native `background=true`, разные точные session IDs. Оба реально
исполнили `shell` с `sleep 20` и вернули `CHILD_ONE` / `CHILD_TWO`. Проверены
одновременная работа, spinner, `gd`/`<BS>`, SSE reconnect, обе completion
notifications и idle родителя. Новый сервер и Neovim затем прочитали исходную
тестовую базу без ключа и без новых prompts; итоговые индикаторы остановились.
Удаление root при задержанных HTTP callbacks удалило оба children без воскрешения.

Основная матрица использовала MiMo V2.5 Free. Успешный предыдущий Go/GLM-5.3-Flash
прогон также состоялся; final background fixture соответствует последнему выбору
пользователя — DeepSeek V4 Flash. Личный ключ использован только по явному
разрешению, через environment отдельного provider. В fixtures, logs и тестовых
профилях ключ не найден; личная credential database открывалась read-only.

## Границы доказательств

- Проверена именно CLI/plugin/client/schema **2.0.11**, bundled plugin **2.0.11-2**,
  review RPC protocol 1. Это не утверждение о будущих версиях сервера.
- E03: реальные Plan/Build ответы MiMo и C-a/C-e/C-t; две variants другой модели
  подтверждены native session settings через тот же prepare, который использует
  send. Генерация на этой другой модели не выполнялась; у MiMo variants нет.
- E17: настоящие native integration endpoints и keyboard UI с публичным fixture
  provider для key/OAuth/code/auto/command. Это не вход в сторонние OAuth аккаунты.
- E22: несовместимый `/api/info` проверен TCP fixture 1.9.0; missing/obsolete plugin
  проверены настоящей CLI 2.0.11. CLI v1 для этого сценария не использовалась.
- Clipboard input использовал изолированный PNG source shim; личный clipboard
  не читался. Current v2 history проверялась; старый v1 импорт исключён.
- PNG получены из настоящего Neovim linegrid; Menlo не рисует некоторые emoji.
  Keyboard focus, Unicode bytes и cursor дополнительно проверены через API.
- Baseline охватывает общий renderer/layout fixture и 30 render timings, а не
  производительность сети в произвольном проекте. Resize исправление намеренно
  меняет размещение input и info bar после уменьшения окна.
- HTTP/Basic без прямого TLS; file URI относится к server FS. External server
  review по умолчанию применяет файлы сервером; manual/native diff требуют
  явно заданного shared filesystem. Native TODO store заменён persistent plugin
  store; MCP tool definitions и runtime LSP отсутствуют в публичном API 2.0.11.
- Zen Free отклонил subagents; ограничение не обходилось. Background execution
  подтверждён разрешённым пользователем OpenCode Go.

Старую ветку/checkout и конфигурацию можно сохранить для v1; откат Lua не означает
откат server database. Установщик сохраняет изменяемую конфигурацию и backups.
