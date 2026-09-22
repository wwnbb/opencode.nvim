# 04. Разрешения и формы

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: сохранить управление разрешениями и вопросами из Neovim, перенести их на **session-scoped permissions** и **Form API** OpenCode 2.0.11, включая восстановление состояния и ответы из другого клиента.

Зависимости: HTTP [плана 1](01-http-client-and-lifecycle.md), события/session context [плана 3](03-messages-events-and-sync.md). Diff review из [плана 5](05-server-tools-and-edit-review.md) использует собственный plugin RPC; native permissions остаются отдельной проверкой политики доступа. UI-проверки — [план 7](07-ui-and-end-to-end-validation.md).

## 1. Файлы и владельцы

| Файлы | Изменение |
|---|---|
| `permission/state.lua`, `permission/danger.lua` | Context session/location/source и состояния отправки решения |
| `events/handlers/permission.lua`, `events/handlers/permission_flow/*.lua` | Нормализация v2 Request, recovery, review routing, replies |
| `question/state.lua`, `events/handlers/question.lua` | Расширение до typed forms, pending/replied/cancelled lifecycle |
| `ui/question_widget.lua`, `ui/chat/questions.lua` | Поля forms, значение отдельно от label, валидация и отображение |
| `ui/permission_widget.lua`, `ui/chat/permissions.lua` | Читаемые action/resources, обработка failed/uncertain reply |
| `ui/chat/interactions.lua`, `widget_index.lua`, `widget_renderer.lua`, `keymaps.lua` | Привязка формы к session/виджету, controls |
| `client/init.lua`, `actions.lua`, `init.lua`, `session.lua` | Методы reply/cancel с явными session ID |
| `cleanup.lua`, `events/util.lua`, `state.lua` | Generations, relevant session tree, invalidation при reload/close |

`question/state.lua` можно сохранить как владельца и эволюционировать его DTO. Если переименовывать в `form/state.lua`, делать это единым рефакторингом с adapter для старых callers; не оставлять две расходящиеся таблицы pending requests.

## 2. Permissions: контракт и преобразования

Источник: [HTTP OpenAPI](https://opencode.ai/v2/openapi.json), [Permission.Request/Reply 2.0.11](https://unpkg.com/@opencode/client@2.0.11/dist/promise/generated/types.d.ts).

| Сущность | V1 в текущем коде | V2 |
|---|---|---|
| Action | `permission`/внутренний `type` | `action` |
| Ресурсы | `patterns` | `resources: string[]` |
| Правила «запомнить» | `always` | `save?: string[]` |
| Связь с tool | Поля tool/call в разных metadata | `source={type:"tool",messageID,id}` |
| Контекст | directory из event/header и session | `sessionID` в request, optional `event.location` |
| Ответ | `{reply:"once"}` | `{decision:"once"}` |
| Endpoint ответа | `/permission/{id}/reply` | `/api/session/{sid}/permission/{id}/reply` |

`decision` принимает `once`, `always`, `reject`; optional `message` сохраняет причину отказа. `permission.replied` в SSE при этом содержит поле **`reply`**, не `decision`. Не заменять имя глобальным поиском по всему коду.

Получение: `GET /api/permission/request` — pending по серверу; `GET /api/session/{sid}/permission` — pending конкретной session; `GET /api/session/{sid}/permission/{rid}` — один request. Reply возвращает `204`.

Входной адаптер может сохранять старые внутренние имена `type/patterns`, чтобы не переписывать каждый widget. Вместе с ними сохранить native request и `source.id` как tool call ID. Поиск tool part выполнять через индекс `(sessionID,messageID,callID)`, а не прямым сравнением request ID и part ID.

## 3. Permission lifecycle

1. При `permission.asked` нормализовать `event.data`, проверить relevant session tree и upsert по request ID.
2. Отдельно сохранить immutable routing context `{sessionID,location,connection_generation}`.
3. Различать native permission и custom review RPC по подтверждённому типу источника. Для bundled v2 tools proposal приходит через RPC плана 5, а не через `permission.asked`. Совместимость с чужим native permission, содержащим `metadata.opencode_native_diff`, допустима только при явном контракте такого источника. Одних имени tool или произвольной строки `diff` недостаточно для включения edit flow.
4. При выборе решения поставить submitting, запретить повторное нажатие; состояние resolved фиксировать после подтверждения HTTP либо соответствующего SSE.
5. Если SSE reply пришёл раньше HTTP callback — закрыть request один раз. Поздний error уже завершённого request должен быть проверен на актуальность, а не повторно открыть widget.
6. При сетевой ошибке до подтверждения показать failed/uncertain и перечитать pending/detail. Исчезновение request не означает автоматически `once` или `reject`.
7. При 404/удалённой session закрыть несуществующий запрос с нейтральным объяснением; не применять файловые операции повторно.
8. При ответе из другого клиента обновить native permission widget. Custom review завершается своим RPC, поэтому локальные file decisions нельзя объявлять принятыми лишь потому, что другой клиент разрешил весь tool.
9. При `location.shutdown`/server restart инвалидировать transient requests старого поколения, затем получить новые списки. Не восстанавливать уже несуществующее ожидание из локального cache.

Danger mode сохраняет существующее явное включение пользователем. Перед ответом учитывать актуальный action/session. Автоответ `once` не должен незаметно создавать persistent `always`-правила. Восстановленный запрос также проходит дедупликацию; один request получает максимум один одновременный reply.

## 4. Формы заменяют прежний Question API

### 4.1. Маршруты

| Назначение | Маршрут |
|---|---|
| Все pending forms | `GET /api/form` |
| Формы session | `GET /api/session/{sid}/form` |
| Детали и состояние | `GET /api/session/{sid}/form/{fid}` |
| Ответ | `POST /api/session/{sid}/form/{fid}/reply` с `{answer:{…}}` |
| Отмена | `DELETE /api/session/{sid}/form/{fid}` |

`Form.Info` содержит `id`, `sessionID`, `title`, `fields`, optional `metadata`. `Form.Detail` дополняет это объектом `state` с `state.status`: `pending`, `answered` с `state.answer` либо `cancelled`.

SSE:

- `form.created`: `data.form` — полная Form.Info;
- `form.replied`: `data={id,sessionID,answer}`;
- `form.cancelled`: `data={id,sessionID}`.

Это три разные формы payload; общего `data.questions` больше нет.

### 4.2. Answer — object по ключам

```json
{
  "answer": {
    "target": "production",
    "checks": ["unit", "integration"],
    "retries": 2,
    "confirm": false
  }
}
```

Имена здесь иллюстративные. Отправляются `field.key` и `option.value`. Отображаемый label, индекс опции и порядковый номер вкладки не являются wire values. Старое `answers: string[][]` не сохраняет числа, boolean и ключи; его нельзя просто обернуть в `{answer=…}`.

## 5. Поддержка каждого типа поля

| Тип Form.Field | Представление в Neovim | Правила |
|---|---|---|
| `string` без options | Текстовый input/popup | required, default, min/max length, format, pattern |
| `string` с options | Существующий single-select | label отдельно от value; `custom` разрешает пользовательский вариант |
| `multiselect` | Существующий multi-select | Массив values; min/max items; custom и default по схеме |
| `number` | Текстовый ввод с преобразованием | Число JSON, minimum/maximum, default |
| `integer` | Числовой ввод | Дополнительно целочисленность; `2.5` не округлять молча |
| `boolean` | Явный yes/no или toggle | false — допустимый ответ, не отсутствие |
| `external` | Описание и ссылка на внешний шаг | Не подставлять фиктивное true/string; completion подтвердить состоянием сервера |

Numeric constraints 2.0.11 — `minimum`/`maximum`; не добавлять неподтверждённые `multipleOf` или exclusive bounds. `when` содержит массив условий `{key,op:"eq"|"neq",value}`; `hidden` и условная видимость не должны ломать навигацию и готовность формы. `external` — отдельная структура с `key`, `url`, optional `title/description`, без общих `required/hidden/when`; не переносить на неё поля других вариантов.

Общий form DTO хранит:

- immutable fields с ключами и исходными constraints;
- draft values по field key и отдельный признак присутствия значения;
- видимые/доступные поля, текущий focus/tab;
- field errors и form-level server error;
- submission state, native form state, generation/context;
- metadata без предположения, что каждая форма привязана к tool call.

`get_answers()` заменить/дополнить построением typed answer. При необходимости старый массив поддерживается только внутренним adapter legacy question widget. Источником отправки остаётся object по ключам.

### 5.1. Условные поля и validation

1. После изменения значения пересчитать visibility по проверенной серверной семантике R8.
2. Не сравнивать `false`, `0`, `""`, `nil` и отсутствующий ключ как одно состояние.
3. Сохранить draft скрытого поля, чтобы возврат к предыдущему выбору не терял ввод; при сериализации следовать правилу сервера о включении скрытых полей, подтверждённому R8.
4. Не преобразовывать regex JSON/JavaScript непосредственно в Lua patterns: синтаксис различается. Выполнять только корректно поддерживаемые локальные проверки, оставляя сервер финальным валидатором; показывать server errors у поля, где это возможно.
5. Unknown field type не теряется. Отобразить диагностическое сообщение, сохранить payload и возможность отмены; до заявленной поддержки новой версии добавить renderer.
6. Defaults не равны автоматическому ответу: пользователь должен подтвердить форму существующим действием submit.
7. При validation error сохранить все draft values, вернуть focus к проблемному полю и разрешить исправление.

Существующий механизм нескольких tabs можно использовать для полей формы. Summary-confirmation должен показывать label и фактическое введённое значение, не сырые HTTP-поля.

### 5.2. Привязка к чату

Форма может появиться без tool/message metadata, в том числе от интеграции. Не выводить message ID из `frm_*` или из ближайшего assistant message. Если достоверной связи нет — показать session-level interaction в существующем механизме orphan widgets.

Отдельно различать form в session и форму параметров метода авторизации из плана 6. Они могут использовать одинаковый renderer/schema helpers, но имеют разных владельцев submission и разные endpoints.

## 6. Recovery и гонки

Сохранить уже существующие исправления в `question/state.lua`, `events/handlers/question.lua`, `events/util.lua` и тестах recovery.

Алгоритм для pending lists:

1. Подписаться на replied/cancelled до HTTP snapshot.
2. Зафиксировать generation запроса и набор terminal IDs, пришедших за время загрузки.
3. Upsert pending только если request ещё актуален и не завершён текущим SSE.
4. Не сбрасывать draft/submitting состояние уже существующей pending формы повторным snapshot.
5. Для disappeared entries проверить авторитетность списка и принадлежность scope. Частичная/ошибочная загрузка не очищает все взаимодействия.
6. При reconnect сверить native Form.Detail для uncertain submissions. State `answered` содержит фактический answer; показать его, даже если он отличается от локального draft.
7. Закрытие chat window сохраняет серверное ожидание, если текущий UX не говорит обратного. Удаление session и отмена формы — отдельные явные действия.
8. Late callback после cleanup не восстанавливает старую форму.

R4 проверяет native permission policy и её порядок относительно custom review. HTTP-метод `permission.create` существует в полном сетевом клиенте, но не предоставлен Plugin.Context 2.0.11. Не закладывать его вызов из bundled tools; план 5 использует публичный plugin RPC. Само значение `effect="ask"` не означает разрешения операции.

## 7. Порядок реализации

1. Ввести нормализатор Permission.Request и обновить signatures reply с session ID.
2. Проверить permission ask/reply/danger/recovery без edit tools.
3. Добавить Form.Info/Detail и typed answer в владельца состояния.
4. Перевести form events, list/detail/reply/cancel; сначала single/multiselect, затем остальные типы до финального завершения.
5. Согласовать submission helpers с `actions.lua`, запретив прямые HTTP-вызовы из UI.
6. Добавить условную видимость, validation, server error recovery и external step.
7. Подключить review RPC, проверить раздельный routing native permission/custom review и source/call correlation.
8. Проверить параллельные формы/permissions в root/child sessions и разные directories.
9. Обновить help/keymaps только там, где появились новые доступные действия.

## 8. Тесты

Существующие: `tests/checks/question_flow_spec.lua`, `permission_recovery_spec.lua`, `native_diff_review_lifecycle_spec.lua`, `tests/unit/question_recovery_spec.lua`, `edit_state_gate_spec.lua`, `session_close_child_cleanup_spec.lua`.

Новые: `permission_v2_spec.lua`, `form_state_v2_spec.lua`, `form_recovery_v2_spec.lua`, `tests/integration/form_widget_v2_spec.lua`.

| Проверка | Ожидаемый результат |
|---|---|
| `action/resources/save/source` | Точное отображение и правильная связь с tool |
| Reply body и адрес | `decision`, исходный session ID, correct request ID |
| `permission.replied` до HTTP | Один terminal transition |
| Danger mode + повторный asked/snapshot | Единственный `once`, без persistent rule |
| Options с одинаковым label и разным value | Отправляется выбранный value |
| Boolean false, number 0, empty optional | Не теряются при сериализации |
| Нецелое значение integer | Ошибка без скрытого округления |
| Multi min/max и custom | Согласованная проверка локально/на сервере |
| `when`/hidden переключаются | Focus остаётся допустимым, required трактуется правильно |
| Regex несовместим с Lua patterns | Нет ложной локальной валидации; error сервера читаем |
| Вторая клиентская форма без tool context | Видна как session-level widget |
| Ответ/отмена другим клиентом | Native state обновился, повторная отправка заблокирована |
| Reply потерян после принятия сервером | Detail восстанавливает answered и фактический answer |
| Reload во время pending | Старые requests не воскрешаются |
| HTTP pending snapshot после form.cancelled | Cancelled не превращается обратно в pending |
| Две формы root/child | Клавиши действуют на форму под курсором |

Runtime: создать формы каждого поддержанного типа, permission allow/ask/deny, ответить из второго клиента, отключить сеть после submit и выполнить reload. Записать ограничения внешних полей и signal/cancellation в R8/R4.

## 9. Критерии готовности

- [x] Все ответы permission имеют session-scoped адрес и `decision`.
- [x] Request/response/event field names не смешаны.
- [x] Поддержаны все шесть типов Form.Field 2.0.11, а не только прежние вопросы.
- [x] Typed answer round-trip сохраняет ключи, values, числа, false и multi-select.
- [x] Validation/retry не теряет draft пользователя.
- [x] Reconnect и ответы другого клиента не создают повторный prompt или вечное ожидание.
- [x] Review и обычные permission различаются корректно; danger mode остаётся управляемым пользователем.
- [x] Все изменения состояния проходят через существующих владельцев и actions boundary.
