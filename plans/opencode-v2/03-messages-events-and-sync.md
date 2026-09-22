# 03. История, события и синхронизация

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: получить одинаковое итоговое состояние чата из live SSE и HTTP history OpenCode **2.0.11**, сохранив существующие renderers, работу нескольких сессий, дочерние задачи и review.

Зависимости: транспорт [плана 1](01-http-client-and-lifecycle.md), admission [плана 2](02-prompts-and-send-flow.md). Планы 4–7 используют эту проекцию. Это наиболее связанный с остальным кодом этап; его следует выполнять до массового изменения виджетов.

## 1. Исходное состояние

`sync.lua` хранит `message[sessionID]`, `part[messageID]`, статусы, todo и индексы связи task ↔ child session. Сообщения упорядочиваются по времени/ID, parts — binary search по ID. Revision/generation защищают снимки от конкурентных обновлений.

`events/sse_bridge.lua` преобразует события v1 `message.updated`, `message.part.updated`, `message.part.delta`, `session.updated` в локальные события. `events/handlers/message.lua` дополняет обработку reconciliation, todo и recovery orphan parts. `client/sse.lua` уже содержит изменения парсера и handling wrapped/sync events; их нужно сохранить при изменении semantic envelope.

Затрагиваемые существующие модули:

- `client/sse.lua`, `events/sse_bridge.lua`, `events/handlers/message.lua`, `session_store.lua`, `notifications.lua`, `events/util.lua`;
- `sync.lua`, `session.lua`, `session/status.lua`, `session/view.lua`, `session/navigation.lua`, `state.lua`, `cleanup.lua`;
- `ui/chat/message_renderer.lua`, `processing_footer.lua`, `tool_renderer.lua`, `task_children.lua`, `tasks.lua`, `todos.lua`, `file_edit_results.lua`, `render_coordinator.lua`;
- `selectors.lua`, `artifact/changes.lua` — чтение нормализованных данных и инвалидация.

Новые чистые нормализаторы: `protocol/v2/messages.lua`, `protocol/v2/events.lua`. Stateful reducer размещается внутри владельца `sync.lua` или его подмодуля; normalization не должен сам делать HTTP-запросы или вызывать renderer.

## 2. История v2 и модель отображения

Источник: [Session.Message.Info 2.0.11](https://unpkg.com/@opencode/client@2.0.11/dist/promise/generated/types.d.ts). Тип message задаётся `type`, не `role`; session ID обычно известен из контекста запроса и не входит в каждый message DTO.

### 2.1. Все типы сообщений

| V2 type | Проекция в текущий чат | Особенности |
|---|---|---|
| `user` | user message + text/file/mention представления | `text`, `files`, `agents`, `skills`; не `parts` |
| `assistant` | assistant message + упорядоченные parts | `agent`, `model`, `content[]`, `time`, `finish`, `retry`, `error`, `tokens`, `cost` |
| `synthetic` | Служебное/контекстное сообщение | Не показывать как дословно введённый пользователем текст |
| `system` | Служебное сообщение | Сохранить назначение и metadata |
| `skill` | Активированный skill / сообщение истории | Отличать от tool execution `skill` |
| `shell` | Результат shell-команды | Полноценный элемент history, не обязательно tool part assistant |
| `agent-switched` | Компактное уведомление о выборе агента | Не создаёт пользовательский turn |
| `model-switched` | Уведомление о модели/варианте | Исторический выбор не заменять текущим preference |
| `location-switched` | Уведомление и обновление расположения session | Важно для дальнейшего routing |
| `compaction` | Состояние/результат compaction | Running/completed/failed, может иметь потоковый текст |
| `idle` | Граница/служебное состояние | Не генерировать пустой assistant bubble |

Не фильтровать историю только на user/assistant, иначе пропадут границы, shell/skill и компакция. Служебные типы могут отображаться компактно, но должны сохраняться в native store. Не превращать каждый служебный message в новый пользовательский prompt для расчёта длительности.

### 2.2. Assistant content

| V2 | Внутреннее поле | Правило |
|---|---|---|
| `message.type` | `message.role` | Только совместимая часть user/assistant; остальные — явно типизированные notices |
| `message.model.id` | `message.modelID` | Логический catalog ID |
| `message.model.providerID` | `message.providerID` | Без вывода из строки модели |
| `content[].type=text/reasoning` | `part.type`, `part.text` | Сохранить порядок и время reasoning |
| `content[].name` у tool | `part.tool` | Не терять оригинальное имя/namespace |
| Tool `id` | `part.callID` + стабильная tool identity | Не смешивать event ID, message ID и call ID |
| Tool `time.created/ran/completed` | `state.time.start/end` и native time | Уточнить старт длительности: created или ran; применить одинаково во всех UI |
| Tool `state.content[]` | `state.output` как текстовая проекция + полное content | Файлы/URI не выбрасывать |
| Tool `state.metadata` | `state.metadata` | Review и child linkage зависят от точного сохранения |
| `state.error` object | Читаемый текст + native structured error | `tostring(table)` неприемлем |
| Tool `status=streaming` | Внутренний streaming/pending input | Input ещё строка, не декодированный object |

Один tool result может содержать несколько text/file элементов. Для старого renderer собрать text с определённым разделителем и отдельно хранить файлы. Нельзя считать `Tool.Result.output` из plugin API тем же самым, что `state.output` старого Lua DTO.

### 2.3. Идентичность и порядок parts

Сначала закрыть R3 на реальной последовательности нескольких content-блоков. Text/reasoning в HTTP history не имеют старых `prt_*` ID. В SSE есть `ordinal`; у tools собственный call ID. Нельзя считать ordinal индексом Lua-массива без проверки.

Проектное решение:

1. Сохранять native content order отдельно от идентификатора.
2. Tool identity строить из `(sessionID, assistantMessageID, callID)`; она не меняется после snapshot.
3. Для text/reasoning создать детерминированную identity из message ID, типа и проверенного ordinal/позиции. Таблицу соответствия event ordinal ↔ snapshot content хранить в sync-владельце.
4. Ввести внутренний `content_order` либо эквивалентный индекс. Порядок отображения определяется им, а не лексикографическим видом искусственного ID.
5. Если оставить binary search parts по ID, отдельно сортировать render projection по content order. Проверить **все** потребители `get_parts()` и `get_message_render_parts()`, не только главный renderer.
6. При полной замене `content[]` атомарно обновлять parts, порядок, revisions, tool/call indexes. Удалять только доказанно исчезнувшие parts именно этого сообщения.
7. Cursor/expanded state привязывать к устойчивой identity. Устаревшие positions инвалидировать один раз после пересборки.

Нативные сообщения и display projection должны иметь единственного владельца. Если хранить оба представления, описать один путь commit, обновляющий их вместе; UI не должен выбирать случайно между stale native и fresh projected data.

## 3. SSE envelope и события, нужные плагину

V2 envelope содержит `id`, `created`, `type`, optional `location`, `data`; durable события дополнительно содержат `{aggregateID,seq,version}`. Это не старый `{directory,payload:{type,properties}}`. `durable.version` — версия конкретного события, а не версия API.

Список ниже основан на [generated types 2.0.11](https://unpkg.com/@opencode/client@2.0.11/dist/promise/generated/types.d.ts) и опубликованном [клиентском reducer](https://unpkg.com/@opencode/client@2.0.11/dist/chunks/service-atpwm825.js). Последний служит проверкой семантики, а не зависимостью Lua от внутренних имён JS-chunks.

| События | Обработка |
|---|---|
| `server.connected` | Установить transport readiness, запустить recovery нужного поколения |
| `location.shutdown` | Инвалидировать location caches и pending interactions, восстановить после reload |
| `session.created`, `session.renamed`, `session.viewed`, `session.permissions` | Обновить конкретные поля session; не ждать общего `session.updated` |
| `session.agent.selected`, `session.model.selected`, `session.moved` | Обновить подтверждённый selection/location и исторические notices |
| `session.deleted` | Очистить session tree, subscriptions/pending, выбрать допустимую активную вкладку |
| `session.forked` | Обновить происхождение; различать fork boundary и subagent parent |
| `session.inbox.enqueued`, `.delivered`, `.cancelled`, `.delivery.changed` | Корреляция input из плана 2; не трактовать delivery как конец работы |
| `session.execution.started`, `.succeeded`, `.failed`, `.interrupted` | Владение исполнением и terminal outcomes |
| `session.status`, `session.idle` | Busy/retry/idle view, уведомления и остановка спиннеров |
| `session.step.started` | Создать/обновить assistant message по `assistantMessageID`; сброс retry-state по правилам версии |
| `session.step.streamed` | Отметить фактическое начало ответа |
| `session.step.ended`, `.failed` | Завершить шаг, записать usage/finish/error, но не всю session автоматически |
| `session.text.started`, `.delta`, `.ended` | Создание text block, append delta, затем **replace** итоговым text |
| `session.reasoning.started`, `.delta`, `.ended` | Аналогично, с time/provider state |
| `session.tool.input.started`, `.delta`, `.ended` | Создание tool и накопление JSON input как строки |
| `session.tool.called` | Перейти к running с разобранным `input`, сохранить `executed` |
| `session.tool.progress` | Обновить metadata и render revision по call ID |
| `session.tool.success`, `.failed` | Зафиксировать content, metadata, error, time; закрыть running |
| `session.retry.scheduled` | Retry message, время следующей попытки; не создавать новый user turn |
| `session.message.content.updated` | Есть в durable union, но отсутствует в live `V2Event` 2.0.11; не ждать его в SSE. При подтверждённом источнике: атомарная замена content |
| `session.compaction.started`, `.delta`, `.ended`, `.failed` | Отдельная compaction projection, без смешения с обычным ответом |
| `session.revert.staged`, `.cleared`, `.committed` | Инвалидация/обновление history и file changes согласно плану 6 |
| `session.synthetic`, `session.skill.activated`, `session.shell.started`, `.ended` | Служебные messages соответствующего типа |
| `session.usage.updated` | Live session totals; не суммировать повторный snapshot повторно |
| `session.usage.recorded` | Есть в durable union, но отсутствует в live `V2Event`; не делать обязательным источником usage |
| `session.instructions.updated` | Инвалидировать связанный context; не отображать как пользовательский prompt |
| `filesystem.changed` | Обновить file-change данные; не считать это подтверждением принятия review |
| `permission.asked`, `.replied`; `form.created`, `.replied`, `.cancelled` | Передать владельцам взаимодействий, план 4 |
| `provider.updated`, `model.updated`, `agent.updated`, `integration.updated`, `credential.updated`, `credential.switched`, `command.updated`, `config.updated`, `skill.updated`, `mcp.status.changed`, `mcp.resources.changed`, `plugin.updated` | Инвалидация соответствующих каталогов, план 6 |
| Прочие известные native/RPC events | Явно поддержать или игнорировать с диагностикой; unknown не должен ломать stream |

`Session.Event.Durable` и `V2Event` — разные union. Два отмеченных durable типа не входят в публичный live stream contract 2.0.11, хотя их структуры опубликованы в том же файле. Не строить recovery или counters на ожидании их доставки. HTTP history и live `session.usage.updated` остаются необходимыми источниками. Точный список обоих union сохранён в [реестре контрактов](reference/contract-inventory.json).

Имена MCP-событий подтверждены типами версии. Для каждого handler тест должен отправлять event из fixture, а не вручную придуманную строку.

## 4. Правила reducer

1. Дедупликация по envelope `id`, ограниченный cache по generation/session; не по `created` и не по тексту delta.
2. Durable seq отслеживается внутри своего aggregate, не глобально. Version 1 и 2 валидны для разных event types. Публичный live stream не включает все durable types: разрыв seq сам по себе не доказывает потерю сети. Reconciliation делать coalesced и не уходить в бесконечный reconnect из-за штатно скрытого события; отсутствие durable у delta нормально.
3. `text.ended` и `reasoning.ended` содержат полный text: заменить, не дописать.
4. Частичный tool input не декодировать на каждом байте как обязательный JSON; поле `input` в `tool.called` является подтверждённым object.
5. `tool.progress.metadata` обновлять по фактической семантике merge/replace опубликованного reducer и fixture. Не стирать review metadata случайным progress без проверки.
6. События неизвестного assistant/tool не выбрасывать без восстановления: создать provisional identity, запланировать один coalesced fetch, затем reconcile.
7. События после delete/reset со старым generation не воскрешают сущность.
8. `finish="tool-calls"` завершает provider step, но может предшествовать продолжению. Спиннер не должен исчезать до idle/terminal execution.
9. Session outcome, session status и pending interaction — разные признаки. Ожидание разрешения не означает сетевое зависание.
10. Не определять parent user message по строковой близости ID. Если UI нужен synthetic parent link, выводить его из подтверждённого порядка turns и хранить отдельно от нативного поля.

## 5. Recovery: события не воспроизводятся

[Контракт клиента](https://opencode.ai/v2/docs/build/client/#stream-events) гарантирует live-only stream, а не replay. Передача `Last-Event-ID` сама по себе не восстанавливает данные. SSE failure `effect/httpapi/stream/failure` обрабатывать как отказ потока, а не business message.

### 5.1. Набор восстановления

После нового поколения соединения:

1. Поднять подписку и registrar handlers до начала снимков.
2. Обновить session info для открытых runtime roots и известных children.
3. Получить `/api/session/active` один раз для процесса и сопоставить с relevant sessions.
4. Для каждой отображаемой/ожидающей session получить сообщения и inbox.
5. Перечитать pending permission и form списки, с защитой от уже пришедших replies.
6. Инвалидировать catalogs нужных locations.
7. Восстановить todo/subagent данные выбранным проверенным способом.
8. Завершить recovery только после согласованного commit; поздние callbacks старого поколения игнорировать.

Фильтр relevant sessions включает открытые корневые сессии и их известные дочерние сессии. Отсутствие `location` у события не является основанием отбросить глобальное/session событие; сначала использовать `sessionID` и данные владельца session. После move нельзя сравнивать только с текущим cwd.

### 5.2. Гонка HTTP snapshot и delta

`SessionMessagesResponse` не содержит общего watermark, однозначно связывающего snapshot с SSE. Поэтому алгоритм «взять HTTP и дописать все события, пришедшие за время запроса» может удвоить текст. Обратный вариант может затереть уже пришедшие данные.

Сохранить текущие generation/revision guards и расширить их:

- До GET снять session/message revisions.
- Обновлять snapshot-ом безусловно только nodes, не изменявшиеся после capture.
- Для изменившихся nodes применять только доказанно авторитетные terminal/full-content значения либо запланировать reconciliation; не откатывать live projection вслепую.
- Для впервые увиденного активного сообщения с buffered deltas не дописывать их к неизвестно насколько свежему full text. Пометить узел восстанавливаемым, ждать full text/reasoning `.ended` или следующего согласованного fetch. Не ждать `.content.updated`, которого нет в live union.
- При постоянном потоке сохранять уже доступную provisional проекцию и индикатор восстановления. После terminal event выполнить fetch, который даёт точное итоговое содержимое.
- При необходимости использовать повторный fetch после периода без изменений; ограничить coalescing/backoff и число одновременных запросов.

Нельзя выдавать этот консервативный recovery за доказательство идеально точного промежуточного текста в каждый момент. Критерий: отсутствие дублирования/тихой потери и точное итоговое состояние после стабилизации, подтверждённое adversarial tests.

### 5.3. Pagination и удаление

`GET …/message` принимает `order` только для начального запроса, затем opaque cursor; при `type`-фильтре его нужно сохранять. По умолчанию приходит ограниченная страница, а не полная история.

Хранить границы загруженного окна и cursors. При upsert страницы не удалять сообщения вне неё. Для очистки по revert/delete/full content использовать явное событие или полный подтверждённый диапазон. Сохранить существующий distinction между upsert-only переключением session и authoritative reconciliation.

## 6. Дочерние сессии и todo

### 6.1. Subagents

- Использовать `Session.Info.parentID` для дерева; fork info хранить отдельно.
- Получать children через session list с `parentID` и pagination.
- Связь конкретного tool call с child брать из проверенных metadata/result, не только из title и времени.
- Сохранить `sync.record_task_child_session`, runtime-root lookup, переход `gd` и возврат `<BS>`.
- Не завершать spinner дочерней session только потому, что завершился родительский task tool: v2 может делегировать работу в фоне.
- Проверить несколько одновременных tasks с одинаковыми названиями и общий worktree.
- Если v2 использует другие effective tool names, добавить явную классификацию в адаптере и сохранить raw name; не переименовывать любой неизвестный tool в `task`.

### 6.2. Todo: обязательная проверка отсутствующего прямого API

В проверенной HTTP-схеме нет `/api/session/{id}/todo`, а в union событий 2.0.11 отсутствует прежний `todo.updated`. Это подтверждает отсутствие прежнего контракта, но не доказывает отсутствие любых задач/todo внутри v2.

Закрыть R6 следующим образом:

1. Выполнить реальный сценарий построения списка задач; записать tool names, arguments, metadata, content и сохранённую history.
2. Если состояние однозначно восстанавливается из истории инструментов — написать чистый extractor, загружающий достаточную историю, а не только последние 100 сообщений.
3. Если v2 предоставляет новую domain/plugin возможность — использовать её после фиксации фактического контракта.
4. Если надёжного штатного источника нет — в bundled plugin плана 5 ввести собственный versioned RPC для сохранения и чтения todo по session ID плюс событие invalidation. Названия этого RPC являются API нашего плагина, не встроенными маршрутами OpenCode.
5. Добиться восстановления после рестарта и из другой вкладки; parser произвольного естественного текста не является достаточным источником истины.

Todo dock входит в текущую функциональность. Его нельзя молча отключить и считать полный перенос завершённым. Дополнительная реализация при варианте 4 увеличивает объём по сравнению с предварительной оценкой.

## 7. Порядок реализации

1. Записать fixtures полного message lifecycle и event envelope 2.0.11.
2. Ввести native → display преобразование HTTP history со всеми типами сообщений.
3. Согласовать identity/order mapping и revision API; закрыть R3.
4. Ввести semantic SSE decoder отдельно от строкового parser.
5. Реализовать text/reasoning events, затем tools, затем execution/inbox/session events.
6. Перевести permission/forms/catalog consumers на новый envelope без двойной обработки.
7. Добавить pagination, recovery и тесты перестановок HTTP/SSE.
8. Перенести subagent linkage, todo и file-change invalidation.
9. Удалить неиспользуемые v1 semantic ветви только после проверки всех callers. Низкоуровневый SSE parser сохранить.
10. Сравнить live-render и cold history-render одного и того же сценария.

## 8. Тестовая матрица

Существующие: `sse_parser_spec.lua`, `sync_snapshot_spec.lua`, `sync_message_order_spec.lua`, `task_children_spec.lua`, `session_deleted_spec.lua`, `session_close_child_cleanup_spec.lua`, `processing_footer_spec.lua`, `tests/integration/chat_render_freshness_spec.lua`.

Новые: `v2_message_projection_spec.lua`, `v2_event_reducer_spec.lua`, `v2_reconnect_spec.lua`, `v2_todo_recovery_spec.lua`.

| Сценарий | Проверяемый инвариант |
|---|---|
| SSE разбит внутри UTF-8/JSON/CRLF; несколько frames в chunk | Парсер выдаёт те же events, что цельный поток |
| Start → delta → ended | Text совпадает с ended и не удваивается |
| Два text и два reasoning между tools | Порядок/identity одинаковы live и history |
| Tool streaming JSON → running → success/error | Валидные input/state/output/metadata на каждом шаге |
| Progress пришёл раньше создания tool | Один provisional tool, затем корректная полная запись |
| Дубли event ID и full snapshots | Нет повторных строк, usage и task nodes |
| Retry с тем же assistant ID | Предыдущая ошибка/finish не остаётся у нового шага |
| Snapshot возвращается после новых deltas/reply/delete | Не затирает данные и не воскрешает удалённое |
| Disconnect после части text или tool input | После recovery финал совпадает с сервером |
| `step.ended` с `tool-calls` | Session продолжает отображаться работающей |
| Full content replacement удаляет tool | Индексы, positions и expanded state очищаются согласованно |
| Страница истории без старых сообщений | Старая загруженная история не удаляется |
| Три root sessions в разных directories | Только соответствующие caches/вкладки изменяются |
| Фоновая child session после завершения parent tool | Навигация и status child остаются корректными |
| Todo после reconnect/restart | Список восстановлен из доказанного источника |
| Несколько сотен мелких deltas | Render coalesced, UI отвечает, память очереди ограничена |

## 9. Критерии готовности

- [x] R3/R6 и fork/revert часть R9 закрыты; импорт старой истории исключён пользователем.
- [x] Нет зависимости от событий `message.part.*` и общего `session.updated` для работы v2.
- [x] Все типы history сохраняются; всё пользовательски значимое имеет представление в UI.
- [x] SSE и HTTP дают одинаковые итоговые parts, metadata, ordering, totals и session status.
- [x] Recovery не зависит от несуществующего replay и не склеивает unversioned deltas вслепую.
- [x] Revisions/generations сохраняют уже имеющиеся исправления конкурентного доступа.
- [x] Дочерние сессии, todo и изменение directory не теряются при reconnect.
- [x] Rendering coalesced; нет нового HTTP GET на каждый токен.
