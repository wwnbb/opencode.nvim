# 01. HTTP-клиент и жизненный цикл сервера

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: обеспечить корректное подключение opencode.nvim к **OpenCode 2.0.11** и сохранить существующий callback-интерфейс там, где его семантика остаётся верной.

Зависимости: исходный контракт и правила из [общего плана](README.md). Планы 2–6 используют этот слой. Этот этап не должен самостоятельно переопределять семантику сообщений, форм и review.

## 1. Исходное состояние

| Существующий файл | Что он делает | Что изменить |
|---|---|---|
| `lua/opencode/client/init.lua` | Фасад примерно четырёх десятков операций, маршруты v1 | Делегировать v2-запросы; разделить wire DTO и совместимые внутренние ответы |
| `lua/opencode/client/http.lua` | JSON, headers, URL query, обработка HTTP status | Добавить deep-object query, endpoint-specific envelope, нормализованные ошибки |
| `lua/opencode/client/auth.lua` | Basic Auth | Сохранить для private/registered service; не заменять на Bearer по одному примеру документации |
| `lua/opencode/client/sse.lua` | `/global/event`, headers и парсер SSE | Переключить endpoint на `/api/event`; semantic decoding вынести в план 3 |
| `lua/opencode/client/transport.lua` | TCP, HTTP framing и streaming | Переиспользовать; менять только при воспроизводимом несовпадении сервера |
| `lua/opencode/client/http_decoder.lua` | Потоковый HTTP-декодер | Сохранить chunked/partial-body поведение и тесты |
| `lua/opencode/client/tcp_connection.lua` | Закрытие соединений | Сохранить exactly-once cleanup |
| `lua/opencode/lifecycle.lua` | `serve --hostname … --port`, stdout parsing, health, process ownership | Новый probe и проверенный способ получения порта; не потерять защиту от устаревших callback |
| `lua/opencode/config.lua`, `init.lua`, `state.lua`, `cleanup.lua` | Настройки подключения, состояние и teardown | Явно хранить проверенный backend/version и владельца процесса |

Сегодня `http.health()` вызывает `/global/health`, а lifecycle требует `data.healthy`. V2 предоставляет `/api/info` с `version`, `pid`, `urls`, `paths`; поля `healthy` в этой схеме нет. Простая замена пути без исправления readiness не даст подключиться.

## 2. Подтверждённые контракты

Источник: [OpenAPI](https://opencode.ai/v2/openapi.json), опубликованный [service client 2.0.11](https://unpkg.com/@opencode/client@2.0.11/dist/promise/service.js).

### 2.1. Основные маршруты

`{sid}` ниже — URL-encoded session ID, `{rid}` — request ID. Таблица задаёт маршрутизацию; семантика сложных операций раскрыта в других планах.

| Сейчас | V2 | Замечание |
|---|---|---|
| `GET /global/health` | `GET /api/info` | Ответ без `data` и без `healthy` |
| `GET /global/event` | `GET /api/event` | SSE всех locations |
| `GET /session` | `GET /api/session` | `{data,cursor}`; `roots=true` → `parentID=null` как строка query |
| `POST /session` | `POST /api/session` | `location`, `agent`, `model`, `permissions`; `{data: Session.Info}` |
| `GET /session/{sid}` | `GET /api/session/{sid}` | `{data: Session.Info}` |
| `DELETE /session/{sid}` | `DELETE /api/session/{sid}` | `204`; удаляются также дочерние сессии |
| `GET /session/status` | `GET /api/session/active` + события статуса | Active показывает владение исполнением, не полный retry DTO |
| `GET /session/{sid}/children` | `GET /api/session?parentID={sid}` | Обязательно учитывать pagination |
| `POST /session/{sid}/fork` | `POST /api/session/{sid}/fork` | `before`, а не старый `messageID` |
| `GET /session/{sid}/message` | `GET /api/session/{sid}/message` | `{data,cursor}`; структура messages новая |
| `POST …/message`, `POST …/prompt_async` | `POST /api/session/{sid}/prompt` | Одна операция принятия input; план 2 |
| `POST …/abort` | `POST /api/session/{sid}/interrupt` | `{interrupted: boolean}`; опция `resume` в query |
| `GET …/diff` | `GET /api/session/{sid}/diff` | `from`, `to`, `context`; план 6 |
| `POST …/revert` | `POST …/revert/stage`, затем commit/clear по намерению | Не механическое переименование |
| `POST …/summarize` | `POST /api/session/{sid}/compact` | Ответ — inbox item |
| `GET /permission` | `GET /api/permission/request` | Глобальный список, фильтрация session/location в плагине |
| `POST /permission/{rid}/reply` | `POST /api/session/{sid}/permission/{rid}/reply` | `{decision,message?}`; нужен session ID |
| `/question…` | `/api/form`, `/api/session/{sid}/form…` | План 4; изменены данные и операции |
| `GET /provider`, `/config/providers` | `GET /api/provider`, `/api/model`, `/api/model/default` | Каталоги разделены |
| `/provider/auth`, `/auth/{provider}`, `/provider/{provider}/oauth…` | `/api/integration…`, `/api/credential…` | Нет взаимно однозначного rename; план 6 |
| `GET /agent`, `/skill`, `/mcp` | `GET /api/agent`, `/api/skill`, `/api/mcp` | Location-scoped envelopes |
| `POST /mcp/{name}/connect`, `…/disconnect` | `POST /api/experimental/mcp/{server}/connect`, `…/disconnect` | Experimental; имя кодировать как отдельный segment, зафиксировать версию |
| `GET /global/config` | `GET /api/config` | Массив Config.Entry, не готовый объединённый config object |
| `POST /session/{sid}/command` | `POST /api/session/{sid}/command` | `{name,text,…}`, `204` |
| `POST /instance/dispose` | `POST /api/location/reload` только для операции reload | Меняет все загруженные locations; не использовать автоматически после auth |
| `GET /session/{sid}/todo` | Прямого маршрута в проверенной схеме нет | Решение R6; планы 3 и 5 |
| `GET /lsp`, `/formatter` | Прямых эквивалентов в проверенной схеме нет | Статус UI пересмотреть, не опрашивать отсутствующие маршруты |
| Новый transport bundled review | `POST /api/rpc/{rpcID}/{method}` | `{input}` → `{output}`; custom protocol плана 5, location-scoped |

Проверить всю таблицу против generated client 2.0.11 и `/doc` либо фактической схемы конкретного сервера, если он её публикует. Не предполагать наличие у v2 старого `/doc`: способ получения runtime schema сначала проверить; опубликованная OpenAPI уже доступна отдельно.

### 2.2. Обработка ответов

Различать четыре формы успешного ответа:

1. `{data: value}` — ресурс или результат.
2. `{location: ref, data: value}` — каталог/операция в location.
3. `{data: array, cursor: {previous?,next?}}` — страница.
4. Bare object/array или `204` — например `/api/info`, `/api/config`, interrupt.

Запретить универсальное `return body.data or body`: `data=null`, `false`, пустой список и отсутствие `data` имеют разный смысл. Описать ожидаемую форму на уровне операции в `client/v2.lua`. Внутренний фасад может возвращать нормализованный value, но pagination/location должны быть доступны вызывающему коду и не теряться.

Сохранить различие `{}` и `[]`: тела с optional-полями кодировать как object через `vim.empty_dict()`. Отсутствие значения, JSON null и пустая таблица не взаимозаменяемы. Не удалять `false` при фильтрации optional-параметров.

### 2.3. Location и кодирование URL

Для location-scoped GET схема задаёт query `location` со стилем `deepObject`. Передавать `location[directory]=…` с корректным percent encoding имени ключа и значения. Для создания session location находится в JSON body. В списке session фильтр `directory` — отдельный query, не вложенный location.

Снимать адресат операции один раз: `{session_id, directory, connection_generation}`. Не вызывать `getcwd()` повторно после переключения вкладки, ответа popup или HTTP retry. Данные `Session.Info.location.directory` преобразовывать во внутреннее поле directory только в одном адаптере.

Заголовок `x-opencode-directory` использовать лишь после проверки его поддержки в 2.0.11. Основной путь должен работать с документированными location parameters. Кодировать ID/name/provider/integration/credential по сегментам; не кодировать весь уже собранный URL повторно.

## 3. Запуск и обнаружение сервера

### 3.1. Первый поддерживаемый режим: собственный private server

Сохранить текущую модель владения: плагин запускает процесс и имеет право останавливать только этот процесс. До написания spawn adapter закрыть R1:

1. Записать `opencode --version` и `opencode serve --help` для 2.0.11.
2. Проверить выбор динамического порта. Текущий `--port` без значения нельзя переносить без проверки. Если поддерживается `--port 0`, зафиксировать это fixture; иначе выбрать проверенный вариант и обработать `EADDRINUSE`.
3. Записать формат объявления URL на stdout/stderr. Не полагаться на строку v1 `opencode server listening on …`.
4. Проверить готовность через `/api/info`: HTTP success + валидная форма + совместимая version. При запуске сервер может отвечать до завершения внутренней подготовки; учесть фактические status codes, а не только появление TCP listener.
5. Проверить auth env и `OPENCODE_CONFIG_DIR` в private mode; подтвердить, что процесс загрузил bundled tools из нужного config dir.
6. Провести timeout → terminate → observed exit; порт и PID не должны оставаться в state.

Сохранить `attempt_generation`, connection token, exactly-once startup callback и остановку таймеров. Старый callback предыдущего процесса не может объявить новый сервер подключённым или завершить его.

### 3.2. Подключение к внешнему серверу

Явные host/port/auth имеют приоритет. Probe проверяет целевой сервер, не запускает новый по умолчанию при `401`, не меняет credentials и не убивает внешний PID. Disconnect закрывает клиентский SSE/TCP и transient state; сервер продолжает работу.

Текущий transport — обычный TCP HTTP. Не обещать поддержку HTTPS автоматически: если настройка удалённого сервера допускает TLS, либо добавить явно протестированный TLS transport, либо показать точное ограничение. Для переноса существующего localhost-профиля достаточно подтверждённого HTTP.

### 3.3. Shared service как отдельный, необязательный режим

Опубликованный service client ищет `${XDG_STATE_HOME:-~/.local/state}/opencode/service.json`, проверяет `/api/info`, PID и version. Auth зарегистрированного endpoint — Basic с username `opencode` и password из регистрации. Документация допускает запуск `opencode serve --service`.

Если добавлять discovery в Lua, повторить проверки identity/version и считать сервер внешним по отношению к Neovim. Нельзя копировать из JS SDK логику автоматического replacement/termination чужого service в обычное `toggle()` плагина. Shared service не нужен для первого private-server переноса, но явно заданное подключение к работающему service должно поддерживаться.

## 4. Изменения по шагам

1. Добавить таблицу операций v2 и endpoint-specific response decoders в новый `client/v2.lua`.
2. Добавить кодирование nested query и ID segments, проверить query boolean/null semantics.
3. Нормализовать ошибку в `{status, code?, message, details?, retryable?}`. Не считать каждый 404 отсутствием функции: это может быть удалённая session/request.
4. Передавать HTTP status и metadata до фасада; обработать `204`, неверный Content-Type, HTML вместо JSON, malformed JSON и обрыв body.
5. Переключить health и lifecycle на проверенный probe v2.
6. Настроить endpoint SSE и передать единый auth/context; semantic parser — план 3.
7. Ввести явную ошибку несовместимой версии. Не отправлять запросы v1 после 401/500 v2.
8. Перевести фасад session CRUD, pagination и базовых каталогов; остальные методы — вместе с владеющим ими планом.
9. Пересмотреть `dispose_server`: имя/действие должны различать reload locations, restart собственного process и reconnect клиента.
10. Пройти existing tests lifecycle/transport/auth и новые контрактные fixtures.

## 5. Тесты

Существующие: `tests/unit/client_auth_spec.lua`, `transport_spec.lua`, `http_decoder_spec.lua`, `lifecycle_spec.lua`, `dispose_server_callback_spec.lua`, `cleanup_spec.lua`, `session_project_scope_spec.lua`.

Предлагаемый `tests/unit/client_v2_spec.lua` должен проверять:

| Сценарий | Ожидаемый результат |
|---|---|
| Location с пробелами, `%`, `#`, кириллицей | Сервер получает исходный путь, без двойного encoding |
| `parentID="null"`, `resume=false`, `data=null` | Значения не исчезают и не превращаются в другие типы |
| Session list больше одной страницы | Cursor сохранён, следующий запрос соответствует исходному фильтру |
| `204` на delete/reply/command | Один success callback, нет JSON parse error |
| `401` | Одна ошибка auth; нет спавна второго сервера и v1 fallback |
| `404` session и `404` неизвестного endpoint | Разные domain/compatibility сообщения |
| Valid JSON error, HTML error, connection reset | Читаемая нормализованная ошибка без секретов |
| SSE использует другой auth, чем REST | Тест должен обнаружить расхождение |
| Старый health callback после restart | Состояние нового подключения не меняется |
| Чужой server PID при disconnect | Не посылается сигнал завершения |
| Собственный процесс завис на старте | Deadline, terminate, cleanup срабатывают один раз |

Прогон: соответствующие отдельные файлы через `./tests/run.sh tests/unit/<file>.lua`, затем затронутые проверки архитектуры. Ручной smoke — private server 2.0.11 и явно настроенный внешний endpoint.

## 6. Критерии готовности

- [x] R1 закрыт реальными выводами CLI и HTTP.
- [x] `/api/info` не проверяется через несуществующий `healthy`.
- [x] Нет потери `cursor`, `location`, `false`, `null` и пустых списков.
- [x] Все используемые методы фасада имеют назначение в v2 либо явно обозначенное решение в следующих планах; отсутствующие маршруты не маскируются пустым успехом.
- [x] Повторный запуск, restart, disconnect и dispose не оставляют stale callbacks/таймеры/сокеты.
- [x] Работа с несколькими directories и переключением session не меняет адресата запроса.
- [x] Auth, server version и ошибки видны пользователю без вывода секретов.

Основной риск: массовая подмена URL при сохранении старых DTO может создать видимость подключения, но сломать все последующие операции. Завершение этого этапа доказывается проверками формы данных, а не только успешным `/api/info`.
