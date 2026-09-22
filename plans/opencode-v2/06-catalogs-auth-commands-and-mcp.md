# 06. Модели, авторизация, команды и MCP

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: восстановить все управляющие функции плагина поверх каталогов и операций OpenCode **2.0.11**, включая выбор моделей/агентов, credentials, команды, skills, MCP, конфигурацию, fork/revert/compact и status popup.

Зависимости: [план 1](01-http-client-and-lifecycle.md), session selection [плана 2](02-prompts-and-send-flow.md), events/history [плана 3](03-messages-events-and-sync.md), общие формы [плана 4](04-permissions-and-forms.md).

## 1. Затронутый код

| Модули | Работа |
|---|---|
| `events/handlers/sync_data.lua` | Новая initial sync и точечная invalidation по каталогам |
| `sync.lua` | Нормализованные catalogs, revision/generation и location scope |
| `local.lua`, `selectors.lua` | ID/display name, defaults, favorites/recent, variants |
| `provider/state.lua` | OAuth attempts и credentials вместо provider-wide boolean state |
| `client/init.lua`, новый `client/v2.lua` | Новые catalog/integration/credential методы |
| `actions.lua`, `init.lua` | Boundary для UI и операции selection/auth/reload |
| `ui/palette/model.lua`, `agent.lua`, `mcp.lua`, `prompt.lua`, `session.lua`, `actions.lua`, `system.lua` | Отображение и вызов новых действий |
| `ui/input/info_bar.lua`, `autocomplete.lua`, `mentions.lua`, `slash_commands.lua` | Актуальные выборы и suggestions |
| `slash.lua`, `commands.lua` | Серверные и локальные команды без смешения контрактов |
| `ui/active_sessions.lua`, `components/lualine.lua` | Status и counters по server state |

Каталоги нормализует новый `protocol/v2/catalogs.lua`. Сначала можно сохранить внутренние формы, которые ожидают существующие menus, но native IDs и location не терять.

## 2. Начальная синхронизация

Источник: [OpenAPI](https://opencode.ai/v2/openapi.json), [типы 2.0.11](https://unpkg.com/@opencode/client@2.0.11/dist/promise/generated/types.d.ts).

| Данные | Endpoint | Форма результата |
|---|---|---|
| Providers | `GET /api/provider` | location + data array |
| Models | `GET /api/model` | location + data array |
| Default model | `GET /api/model/default` | location + data model либо null |
| Agents | `GET /api/agent` | location + data array |
| Integrations/соединения | `GET /api/integration` | location + data по schema |
| Commands | `GET /api/command` | location + data catalog |
| Skills | `GET /api/skill` | location + data catalog |
| MCP | `GET /api/mcp` | location + data array |
| Plugins | `GET /api/plugin` | location + data array |
| Config sources | `GET /api/config` | **bare array Config.Entry**, не `{data}` |

Сейчас initial sync читает `/config/providers`, получает `{providers,default}`, а commands берёт из `config.command`. V2 требует отдельного запроса `/api/command`; каталог активных команд нельзя восстановить простым чтением одного config source, потому что в нём могут отсутствовать plugin-defined entries.

Новая initial sync:

1. Определить location и connection generation.
2. Независимые catalogs загрузить параллельно с ограничением concurrency.
3. Согласованно объединить provider/model/default results только одного location/generation.
4. При частичной ошибке сохранить последнюю успешную запись и показать конкретную ошибку, а не пустой «нет моделей».
5. Первичный выбор делать после readiness необходимых catalogs; transient пустой ответ не запускает destructive cleanup favorites.
6. По SSE invalidation перечитывать конкретный domain с debounce, а не весь server state на каждое событие.
7. Отдельно хранить loading/loaded/failed. Пустой загруженный каталог отличается от ещё не загруженного.

При работе с sessions разных directories cache key должен включать location. Если хранится только один «активный каталог», атомарно менять его при переключении и не использовать для отправки в другую session; предпочтительно добавить location-indexed records и сохранить selectors текущей session.

## 3. Модели, агенты, variants и предпочтения

### 3.1. Идентификаторы

`Model.Info.id` — logical ID каталога; `modelID` — отдельное поле модели upstream. В `Model.Ref` отправляется `{providerID,id,variant?}`. Внутренний старый `{providerID,modelID}` можно временно сохранить только с явным правилом: это имя поля представляет **catalog id**. Upstream ID хранить отдельно, например в native model record.

`Agent.Info` имеет и `id`, и `name`. Сегодня `local.lua` и palette выбирают agent по `name`. Перейти к stable ID для selection, а name оставить для отображения. Если `id==name`, тест всё равно должен включать искусственный случай различия, иначе ошибка останется незаметной.

`Provider.Info` содержит `integrationID` optional. Provider ID не обязан совпадать с integration ID или credential ID. Один integration может обслуживать несколько providers, один provider может иметь несколько доступных connections.

### 3.2. Адаптер catalogs

- Собрать `provider.models[model.id]` из отдельного списка Model.Info, чтобы сохранить текущие readers.
- Фильтровать `enabled`, поддерживать status alpha/beta/deprecated/active по согласованному UX.
- Capabilities брать из `capabilities`, не старых top-level `reasoning/attachment/tool_call`.
- `variants` — массив объектов с `id`, не словарь по имени. Сохранять порядок, если он значим, и не показывать индексы `1,2,3` как имена вариантов.
- `cost` — массив тарифных уровней; нельзя обращаться к нему как к старому object `cost.input`. Если UI показывает стоимость модели, выбрать базовый tier и обозначить остальные либо показать диапазон. Фактические расходы ответа брать из message/session usage.
- Сохранить limits context/output/input и особые значения optional-полей.
- Hidden/subagent agents фильтровать существующими selectors, но explicit false и null не смешивать.

### 3.3. Defaults и сохранённые данные

`/api/model/default` возвращает одну модель или null, а не старый map provider→model. Не изобретать default для каждого provider на основании первого элемента сортировки. Если UI нужен deterministic fallback, описать его как локальную политику, а серверный default сохранить отдельно.

Порядок выбора для новой session: явный аргумент пользователя → сохранённый валидный выбор → agent model, если применим → серверный default → понятная ошибка отсутствия модели. Точный приоритет текущего `local.lua` сохранить там, где он не противоречит session ownership v2.

При загрузке существующей session её model/agent имеют приоритет для отображения фактического состояния. Глобальный preference — значение для следующего выбора, не повод переписывать серверную session без действия пользователя.

Миграция favorites/recent/per-agent selections:

1. Сохранить исходный persistence file перед изменением формата.
2. Ввести version поля формата, если меняется семантика ID.
3. Сопоставить записи с catalog IDs; при однозначном canonical alias выполнить conversion.
4. При неоднозначности сохранить запись как unavailable, не угадывать provider и не удалять историю выбора.
5. Не запускать cleanup до успешной загрузки всех нужных catalogs.
6. Проверить variant, который исчез; выбрать серверный default/none с явным отображением, а не послать недопустимую строку.

## 4. Авторизация: Integration и Credential

Старый flow `provider/auth → numeric method index → oauth authorize/callback → dispose instance` заменить на операции integration. Numeric index больше не является устойчивым идентификатором OAuth method.

### 4.1. API key

1. Загрузить integration и его `methods`, выбрать `type="key"`.
2. Если метод содержит `form`, получить typed answer общим renderer из плана 4.
3. Вызвать `POST /api/integration/{integrationID}/connect/key` с `{key,answer?,label?}`.
4. На `204` перечитать integration connections и model/provider catalogs.
5. Не вызывать `location.reload` автоматически: он отменяет pending forms/permissions во всех locations.

Секрет не писать в logs, input history, fixture или сообщение об ошибке. Ошибки показывать с безопасным описанием. Это требование конкретного auth flow, не новая система хранения ключей в Neovim.

### 4.2. OAuth

| Шаг | Endpoint/данные |
|---|---|
| Начало | `POST /api/integration/{iid}/connect/oauth`, `{methodID,answer?,label?}` |
| Result | `attemptID`, `url`, `instructions`, `mode=auto|code`, `time.created/expires` |
| Проверка | `GET /api/integration/{iid}/connect/oauth/{attemptID}` |
| Завершение code-flow | `POST …/{attemptID}/complete`, `{code?}` |
| Отмена | `DELETE …/{attemptID}` |

Владелец `provider/state.lua` хранит attempt ID, integration ID, location, generation, expiry и состояние popup. Полный callback path не вычисляется из текущего выбора provider в UI.

`auto` flow: открыть URL действием пользователя, bounded polling status до complete/failed/expired или cancellation. `code` flow: запросить code существующим popup, отправить complete, затем подтвердить actual status/catalog refresh.

State machine: idle → starting → awaiting_user/polling → complete/failed/expired/cancelled. `pending` не ошибка. Закрытие popup и disconnect завершают локальные timers; server attempt отменять согласно явному действию пользователя, сохраняя возможность диагностировать неопределённый результат.

V2 также имеет command/env методы integration. В palette отобразить их корректно: env — инструкция/состояние, command — соответствующий command connect/status/cancel flow при поддержке. Не подставлять их в OAuth method с числовым индексом. Поддержка метода определяется его schema и проверенным API.

### 4.3. Несколько connections и отключение

Удаление выполняется через `DELETE /api/credential/{credentialID}`; activation через `/api/credential/{credentialID}/activate`, update — PATCH. Connection.Info содержит связь с credential; schema определяет точные поля.

Операция «Disconnect provider» должна выбрать соответствующее соединение/credential. Если несколько accounts, показать выбор. Если источник — environment, нельзя притворяться, что удаление credential отключило env auth. Не удалять все credentials integration ради старого provider-level UX без явного выбора.

Существующий `pending_disconnect` refactor сохранить с новым ключом credential/integration. Успех подтверждать повторным list, а не только локальным `forget_provider`. Catalog invalidation не должна удалять favorites других providers.

## 5. Команды, slash и skills

### 5.1. Разделение команд

Локальные `/new`, `/models`, help, toggle и другие команды Neovim продолжают исполняться локально. Пользовательские серверные команды брать из `/api/command` и выполнять:

```json
{"name":"review","text":"--staged"}
```

Route: `POST /api/session/{sid}/command`, ответ `204`. Optional вложения имеют тот же input-формат files/agents/skills, есть delivery. В body нет старых `command`, `arguments`, `model`, `variant`; selection подготавливается механизмом плана 2.

`204` означает успешную обработку запроса согласно контракту, не готовый assistant message. Отслеживать execution через events, не вызывать старый response renderer.

Правила конфликтов одинаковых local/server command names должны остаться определёнными. Обновить completion descriptions и перечитывать server commands по `command.updated`.

### 5.2. Skills

Для каталога сохранять skill ID, name, description, location/content согласно схеме. Выбор через palette/input может передаваться native attachment `skills[].id`. Текущий palette строит строку `load_skill [...]`; решить, нужен ли bundled command `commands/load_skills.md` для обратного UX или его действие заменить на структурированное attachment.

Не пересылать большой skill content повторно в prompt, если сервер сам активирует skill по ID. `/api/experimental/session/{sid}/skill` существует, но experimental route не делать обязательной зависимостью, если стабильный prompt attachment покрывает намерение. Проверить, что selected skills сохраняются в истории и показываются renderer плана 7.

## 6. MCP

`GET /api/mcp` возвращает array `{name,status,integrationID?}`. Сегодня UI ожидает map; адаптер может собрать map по name, сохранив native record.

`record.status` — объект со своим discriminator `status`: `connected`, `pending`, `disabled`, `failed`, `needs_auth`. У `failed` и `needs_auth` есть `error`. Читать `record.status.status`, а не сравнивать весь объект со строкой; не сводить неизвестное значение к disconnected.

Connect/disconnect: `POST /api/experimental/mcp/{server}/connect` и `POST /api/experimental/mcp/{server}/disconnect`, с правильным location; `server` — имя сервера. В 2.0.11 изменение MCP находится в experimental namespace, хотя чтение `/api/mcp` — вне него. Это необходимая версия-зависимая часть сохранения текущих connect/disconnect: закрепить fixtures, явно проверять совместимость и не подменять отсутствующий endpoint пустым успехом. Нажатие блокируется на время запроса; затем authoritative refresh. События `mcp.status.changed` и `mcp.resources.changed` обновляют соответствующее состояние.

Если MCP требует авторизации, использовать связанный integration и общие методы auth. Не вычислять OAuth endpoint из server name. В случае async pending показать ожидание, сохранив возможность обновить статус, а не сразу объявлять success connected.

## 7. Session operations, config и status popup

### 7.1. Fork, compact, revert, diff

| Операция | Точный перенос |
|---|---|
| Fork | Body `{before?: messageID}`; граница «до сообщения», проверить старую пользовательскую семантику |
| Compact | `/compact` с optional `id/delivery`; возвращает inbox item, completion по событиям |
| Diff | Query `from`/`to` — user turns, optional `context`; отсутствие from означает последний user turn, а не все изменения session |
| Revert | `/revert/stage` с `{messageID,files?}`, clear через DELETE `/revert`, commit отдельным POST |

Для diff «все изменения session» нельзя оставить запрос без параметров и предполагать прежний результат. Определить нужный диапазон от первого до последнего соответствующего user message с учётом pagination и проверить R9.

Для revert сначала записать состояние history/disk до и после stage, clear, commit на тестовом проекте. Установить, какой шаг соответствует существующей команде undo, восстанавливает ли stage файлы и когда сервер commit-ит staged revert автоматически. Не вызывать stage+commit всегда только ради одного старого метода: это может лишить пользователя возможности отменить staged operation.

Текущий UI не должен очищать все messages после compact либо считать fork обычным subagent task. Parent tree и fork boundary различаются в данных.

### 7.2. Config

`/api/config` — массив sources: `type="document"` с `info` и optional path либо `type="directory"` с path. Не делать `sync.handle_config(response)` как будто это готовый config object.

Для runtime выборов использовать domain catalogs и Session.Info. Если конкретный UI действительно нуждается в config setting, либо получить его из документированного canonical источника, либо реализовать source merge с проверенным порядком; порядок нельзя угадывать по сортировке путей.

Сервер поддерживает значительную часть v1 config. Миграция Lua-плагина не требует массово конвертировать пользовательские configs. Менять bundled configuration ровно настолько, насколько нужно для v2 server plugin, сохраняя посторонние настройки.

### 7.3. Server status

Собирать version из `/api/info`, MCP из `/api/mcp`, plugins из `/api/plugin`. В текущем get_status опрашиваются `/lsp`, `/formatter`, `/global/config`; их прямых аналогов в проверенной схеме нет.

В [migration guide](https://opencode.ai/v2/docs/migrate-v1) указано, что v2 принимает LSP-конфигурацию, но не запускает LSP и не выдаёт LSP diagnostics. Удалить ложный индикатор «LSP подключён» и не считать отсутствие `/lsp` сетевой ошибкой всего сервера. Formatter config, если показан, обозначать именно как configuration, а не подтверждённый runtime status.

Reload `/api/location/reload` пересоздаёт все loaded locations, отменяет pending permissions/forms и требует recovery. Это явное системное действие; обычный auth refresh не должен иметь такой побочный эффект.

## 8. Порядок реализации

1. Минимальные model/provider/default/agent adapters для первого prompt.
2. Location-aware initial sync, generations и readiness.
3. Selection и persistence migration без удаления unavailable favorites.
4. Command/skill catalogs и execution; точечные invalidation events.
5. Integration/credential API и новый state owner OAuth attempts.
6. Palette key/OAuth/command/env flows, multi-connection disconnect.
7. MCP statuses, connect/disconnect/auth.
8. Fork/compact/diff/revert согласно R9, status/config/reload.
9. Обновить LuaDoc/public actions и тесты; удалить callers старых provider endpoints.

## 9. Проверки

Существующие: `pending_disconnect_spec.lua`, `dispose_server_callback_spec.lua`, `input_slash_commands_spec.lua`, `input_mentions_spec.lua`, `palette_config_layout_spec.lua`, `session_project_scope_spec.lua`, `session_deleted_spec.lua`.

Новые: `catalogs_v2_spec.lua`, `selection_v2_spec.lua`, `integration_auth_v2_spec.lua`, `mcp_v2_spec.lua`, `session_operations_v2_spec.lua`.

| Сценарий | Доказательство |
|---|---|
| `model.id != model.modelID`, `agent.id != name` | Отправляются логические IDs, отображаются нужные labels |
| Variants array и cost tiers | Нет numeric variant labels и обращения к отсутствующим полям |
| Default model null | Читаемая ошибка/выбор, без произвольного model ID |
| Partial catalog failure | Рабочие данные/favorites сохранены |
| Смена location при in-flight catalogs | Ответ старого location не меняет selection нового |
| OAuth auto/code/expired/cancel | Один attempt, timers завершены, состояние подтверждено сервером |
| Два credentials одной integration | Удаляется только выбранный credential |
| Provider ID отличается от integration ID | Auth идёт в правильный endpoint |
| Environment connection | UI не обещает отключение через credential delete |
| Command reply 204 | Нет пустого assistant bubble или ложного idle |
| Skill ID отличается от display name | Сервер получает ID, history отображается корректно |
| MCP pending/needs_auth/failed | Отдельные состояния, без ложного connected |
| Diff без from и diff полного диапазона | Не перепутаны последний turn и вся session |
| Revert stage/clear/commit | Сохранены выбранные границы history и disk semantics |
| Auth success при ожидающей форме | Форма не отменена побочным reload |
| LSP отсутствует | Status popup работает и сообщает реальную возможность v2 |

## 10. Критерии готовности

- [x] Все catalogs загружаются и инвалидируются с правильным location.
- [x] IDs, display names, upstream model IDs и credential IDs различаются в моделях данных.
- [x] Сохранённые предпочтения мигрируются без необратимого удаления.
- [x] Key/OAuth и доступные методы integration работают через реальные v2 endpoints.
- [x] Удаление credential и внешнее изменение account отражаются после refresh.
- [x] Commands/skills/MCP доступны в palette и input, errors не теряют пользовательский ввод.
- [x] Fork/compact/revert/diff проверены фактически; исторический импорт из R9 исключён пользователем.
- [x] Config/status UI не отображает несуществующие v1 возможности как работающие.
- [x] Никакой auth-flow не вызывает глобальный reload без нужды.
