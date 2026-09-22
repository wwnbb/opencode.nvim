# 02. Отправка сообщений и управление запросами

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: отправлять пользовательские запросы в OpenCode **2.0.11**, показывать их без дублей и корректно различать локальный ввод, принятие сервером, очередь, исполнение и завершение.

Зависимости: [план 1](01-http-client-and-lifecycle.md), модель истории из [плана 3](03-messages-events-and-sync.md), идентификаторы агента/модели из [плана 6](06-catalogs-auth-commands-and-mcp.md). Проверки UI — [план 7](07-ui-and-end-to-end-validation.md).

## 1. Где менять

| Существующий модуль | Участок |
|---|---|
| `lua/opencode/send.lua` | `build_payload`, `append_payload_part`, `seed_local_message`, `send_prompt`, `send_async_prompt`, `handle_prompt_response`, watchdogs |
| `lua/opencode/client/init.lua` | `send_message`, `send_message_async`, `create_session`, `abort_session`, `execute_command` |
| `lua/opencode/selectors.lua` | `send_selection`: выбор и проверка agent/model/variant |
| `lua/opencode/local.lua` | Локальные предпочтения и выбор следующего запроса |
| `lua/opencode/session/pending.lua`, `session/lock.lua` | Корреляция ожидающего prompt и сериализация операций |
| `lua/opencode/session.lua`, `init.lua`, `actions.lua` | Оркестрация создания, отправки, abort и выбора |
| `lua/opencode/ui/input/attachments.lua`, `mentions.lua`, `slash_commands.lua` | Преобразование вложений, упоминаний, серверных команд |
| `lua/opencode/clipboard.lua` | Изображения и текст из clipboard |

Новый чистый модуль `protocol/v2/requests.lua` должен собирать wire body. Он не создаёт session, не посылает запросы и не меняет sync.

Сейчас `send.lua` создаёт `messageID`, `parts[].id`, `agent`, `model`, `variant`; sync-вызов ожидает assistant response и затем выставляет idle. В v2 оба предположения меняются.

## 2. Контракт v2

Источник: [HTTP API](https://opencode.ai/v2/docs/api) и [generated types 2.0.11](https://unpkg.com/@opencode/client@2.0.11/dist/promise/generated/types.d.ts).

```http
POST /api/session/{sessionID}/prompt
Content-Type: application/json

{
  "id": "msg_<client-generated-id>",
  "text": "Проверь этот файл",
  "files": [{"uri": "file:///workspace/src/main.lua", "name": "main.lua"}],
  "agents": [{"name": "explore"}],
  "skills": [{"id": "review"}],
  "delivery": "queue",
  "resume": true
}
```

Это иллюстрация структуры, не утверждение, что конкретные agent/skill уже установлены. Реальная поддержка URI проверяется задачей R7. Только `text` обязателен; не добавлять неиспользуемые массивы и не отправлять неизвестные поля.

Успех: `200 {data: Session.Inbox.User}`. Объект содержит `id`, `sessionID`, `time.created`, `type="user"`, `payload`, `delivery`. Он подтверждает admission, а не полный assistant message.

В body prompt **нет** старых `parts`, `messageID`, `agent`, `model`, `variant`, `noReply`, `tools`, `system`. Если эти опции используются публичным Lua API, для каждой задать явное преобразование либо понятную ошибку до отправки. Нельзя молча выбрасывать параметр, меняющий смысл запроса.

Модель задаётся как `{providerID, id, variant?}` при создании session или отдельной операцией `POST /api/session/{sid}/model`. `id` — логический ID записи каталога, не автоматически `model.modelID` upstream-провайдера. Агент переключается через `/api/session/{sid}/agent`.

`delivery` принимает `steer` или `queue`. `resume=false` допускается контрактом, но не является прямым эквивалентом старого `noReply`: сообщение остаётся в системе admission/inbox. Действительное поведение фиксировать тестом.

## 3. Целевая модель отправки

Хранить внутреннюю запись отправки, например:

```lua
-- Проектируемый внутренний DTO; не HTTP body.
{
  session_id = "ses_...",
  message_id = "msg_...",
  connection_generation = 12,
  selection = { agent = "build", model = { providerID = "...", id = "..." } },
  status = "submitting", -- accepted / queued / delivered / failed / uncertain / cancelled
  text = "...",
  attachments = {},
}
```

`message_id` генерируется один раз для одного пользовательского действия. Не создавать новый ID автоматически после timeout. Связь inbox item → пользовательское сообщение хранить по ID; не сравнивать только текст и время.

Владельцем pending/outbox сделать существующий session pending слой с явными mutators. UI читает derived state. Не размазывать `accepted`/`uncertain` между view state, глобальным `state` и несколькими независимыми таблицами.

### 3.1. Создание новой сессии

1. Снять текущие текст, вложения, directory и выбранные значения.
2. Проверить agent/model/variant по уже загруженным каталогам.
3. Один раз создать session с `location`, `agent`, `model`; не использовать `parentID` в create body — его там нет.
4. Зарегистрировать результат через `session.lua`, сохранив реальный session ID.
5. Отправить prompt в эту session независимо от последующей смены вкладки.
6. При ошибке создания сохранить исходный ввод и вернуть состояние кнопки/клавиши отправки.

### 3.2. Отправка в существующую сессию

1. Получить фактические agent/model session из серверного состояния, не из глобального preference.
2. Сравнить с желаемым выбором, зафиксированным для конкретной отправки.
3. Сериализовать `switchAgent → switchModel → prompt` для одной session. Если агент меняет default model, явная модель применяется после агента.
4. После каждой ошибки остановить цепочку; не посылать запрос с другой моделью без уведомления.
5. При успехе сохранить подтверждённые значения session; local preference остаётся ответственностью `local.lua`.

Эта последовательность защищает от гонок внутри Neovim, но не является транзакцией относительно второго клиента. При внешнем переключении или активной генерации показать фактический выбор по событиям, перечитать session и не обещать атомарность, которой нет в API. Проверить серверную семантику queued prompts: выбор может действовать для последующих шагов session, а не быть зафиксированным в каждом inbox item.

### 3.3. Admission и локальное отображение

1. До запроса добавить локальное user message с признаком provisional и тем же ID, который отправляется серверу.
2. При HTTP success нормализовать inbox item и обновить существующее сообщение; не добавлять второй экземпляр.
3. `session.inbox.enqueued` может прийти до HTTP callback. Обрабатывать идемпотентно.
4. `session.inbox.delivered` содержит только `inboxID`, без полного текста. Коррелировать с outbox/inbox; если entry неизвестен — перечитать данные.
5. После delivery обновить порядок по подтверждённой семантике сервера. Не фиксировать навсегда optimistic timestamp как время реального delivery.
6. Не вызывать `handle_prompt_response()` со значением `Session.Inbox.User`, будто это старый `{info,parts}`.
7. HTTP callback не устанавливает idle. Исполнение отслеживает план 3.

### 3.4. Обычная и async отправка

Обе используют `/prompt`. Если публичное поведение `send_message` обещало callback после ответа модели, выбрать явную стратегию совместимости:

- transport-метод возвращает admission;
- высокоуровневый метод, которому действительно нужен результат исполнения, ожидает terminal session/turn через события и затем читает history;
- ожидание не держит HTTP prompt бесконечно и не связывает все последующие prompts session с первым callback;
- определить, нужен ли существующим callers именно completed response; не эмулировать ожидание там, где UI ждёт только факт отправки.

Обновить LuaDoc, названия внутренних helpers и tests. Старый `timeout=0` для долгого POST больше не должен быть основным механизмом ожидания генерации.

## 4. Вложения и упоминания

| Текущее представление | Целевое представление | Требуемая проверка |
|---|---|---|
| Text part основного ввода | `text` | Переносы, пустой текст с вложением, Unicode |
| Дополнительный text context | Детерминированно включённый контекст в `text` с обозначением источника | Не теряется порядок и не смешиваются инструкции с содержимым файла |
| File/image part с `url` | `files[].uri` | `file:`, `data:` и remote URI только после R7 |
| Agent mention | `agents[].name` и optional `mention` | Проверить, что wire name соответствует идентификатору каталога |
| Skill mention | `skills[].id` и optional `mention` | Использовать ID, не display name/location |
| Выделение или диапазон строк | URI/description либо текстовый attachment по возможностям сервера | Не выдумывать старые поля `source` в PromptInput |

Входной `PromptInput.FileAttachment` содержит `uri`, optional `name`, `description`, `mention`. В истории файл уже имеет `data`, `mime`, `source`; эти структуры не взаимозаменяемы.

`mention={start,end,text}` требует проверки системы индексов: Lua обычно работает байтами, JavaScript — UTF-16 code units. Зафиксировать conversion helper на строках с кириллицей и emoji. Если reliable offsets не нужны для конкретного attachment, optional mention можно опустить, сохранив само вложение; нельзя посылать заведомо неверные диапазоны.

Clipboard image: сохранять MIME и жизненный цикл временного файла до подтверждения ingestion; не удалять файл до фактического чтения сервером. При remote server локальный путь Neovim не обязательно доступен серверу — выбирать поддерживаемый inline URI либо сообщать об ограничении.

## 5. Очередь, steering и остановка

Сначала сохранить привычную политику UI: если повторная отправка во время работы сейчас блокируется, не включать автоматически steering. Для явно поддержанной отправки во время busy задать `delivery` осознанно и показать queued/steering состояние. Значение `queue` в примере не означает, что каждое действие пользователя обязано идти в очередь.

`POST /api/session/{sid}/interrupt` возвращает `{interrupted}`; `interrupted=false` — idle no-op, не сетевой сбой. `resume=true` по контракту возобновляет часть ожидающих управляющих inputs; для обычного abort не включать его автоматически.

Abort исполнения и удаление ожидающего input — разные операции. Для отмены queued prompt использовать `DELETE /api/session/{sid}/inbox/{inboxID}`. В UI/API точно определить, что делает `<C-c>` при active + queued inputs; не объявлять очередь очищенной только потому, что interrupt завершился успешно.

После interrupt перечитать active/inbox/history и завершить локальные ожидания. Исторические messages и previews не стираются вместе с transient pending state.

## 6. Таймауты и неопределённый результат

1. Если соединение оборвалось после записи body, outcome может быть неизвестен: поставить `uncertain`.
2. Проверить inbox и историю по исходному message ID; также учесть уже полученный `inbox.enqueued`.
3. Если ID найден — считать admission подтверждённым, продолжить наблюдение.
4. Если запрос отвергнут валидированным 4xx до admission — отметить failed, сохранить ввод для исправления.
5. Если ID отсутствует, это ещё не доказывает, что сервер его не принял: учитывать незавершённый предыдущий запрос, пагинацию и задержку наблюдения.
6. До закрытия R2 запретить автоматическое повторение POST с новым ID. После R2 реализовать только доказанную политику retry; одинаковый ID не считать идемпотентным на основании имени поля.
7. Не использовать watchdog «нет assistant через 3 секунды» как доказательство ошибки: input может ждать в очереди или на interaction.

Watchdogs должны проверять inbox/active и сигнализировать о неопределённости. Они не завершают генерацию и не удаляют provisional prompt без подтверждения.

## 7. Проверки

Существующие тесты: `send_flow_spec.lua`, `chat_notice_correlation_spec.lua`, `pending_disconnect_spec.lua`, `input_mentions_spec.lua`, `input_autocomplete_spec.lua`, `input_slash_commands_spec.lua`, `input_history_spec.lua`.

Добавить `tests/unit/send_flow_v2_spec.lua` с матрицей:

| Сценарий | Что доказать |
|---|---|
| Prompt в новой session | Create содержит selection/location, prompt не содержит v1-полей |
| Модель и агент изменены | Правильный порядок switch; prompt не ушёл после failed switch |
| Два быстрых submit | Разные действия имеют разные ID, один submit не выполняется дважды |
| Event раньше HTTP | Один user message, один pending item |
| HTTP раньше event | Та же итоговая проекция |
| Success admission при долгой генерации | Session остаётся busy/queued по реальному состоянию |
| Timeout после admission | Нет повторного запроса к модели, entry восстанавливается по ID |
| Отмена queued input | Удаляется соответствующий inbox item, активный ответ не перепутан |
| Interrupt idle/active | Корректные оба значения `interrupted` |
| Смена вкладки до callback | Сообщение и ошибка принадлежат исходной session |
| Retry провайдера | Не возникает новый optimistic user message |
| Текст + картинка + skill + agent | Вложения дошли в верной форме и отобразились после reload |
| Unicode mention | Offset и текст сохраняют соответствие |
| Close/reset при in-flight | Устаревший callback не возвращает удалённую session |

Runtime-проверка: записать запрос/ответ и последовательность событий одного обычного prompt, одного queued prompt, interrupt, повторного ID и input с изображением. Обезличить содержимое, сохранить будущие fixtures в `tests/fixtures/v2/`.

## 8. Критерии готовности

- [x] R2 и R7 закрыты фактическими трассами.
- [x] Ни один prompt v2 не содержит старые `parts`, `model`, `agent` на верхнем уровне.
- [x] `Model.Ref.id` берётся из логического каталога и не подменяется upstream `modelID`.
- [x] Admission, delivery и execution completion различимы в коде и тестах.
- [x] Selection относится к session/отправке; изменение глобального preference не меняет уже начатую цепочку.
- [x] После timeout и reconnect нет дублирующего user message или повторного вызова модели.
- [x] Вложения, clipboard и mentions проходят round-trip через HTTP history.
- [x] Сценарии cancel/interrupt/close не оставляют вечные pending и таймеры.

Риск этапа — не количество переименованных полей, а сохранение смысла «отправить», «ждать», «остановить». Эти состояния необходимо проверить до интеграции всего UI.
