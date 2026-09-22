# 05. Серверные инструменты и review правок

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: перенести bundled `neovim_edit`, `neovim_apply_patch`, `rg` на публичный API **OpenCode 2.0.11**, сохранив проверку предложений в Neovim, частичное принятие, ручное изменение и точное описание конечного состояния диска.

Зависимости: HTTP/RPC transport [плана 1](01-http-client-and-lifecycle.md), tool events [плана 3](03-messages-events-and-sync.md), взаимодействия [плана 4](04-permissions-and-forms.md), UI [плана 7](07-ui-and-end-to-end-validation.md).

## 1. Что уже существует и должно сохраниться

| Файл | Ценность текущей реализации |
|---|---|
| `opencode_nvim/tool/neovim_edit.ts` | Точная замена, защита от нежелательной смены отступов, proposed/final diff, classification результата |
| `opencode_nvim/tool/neovim_apply_patch.ts` | Парсер patch, add/update/delete/move, проверки before-state, partial review |
| `opencode_nvim/tool/rg.ts` | Формирование argv, фильтры поиска, ограничения результата |
| `opencode_nvim/tool/lib/file_state.ts` | BOM, существование файла, before/current сравнение, безопасная запись/удаление |
| `opencode_nvim/tool/lib/text.ts`, `diff.ts` | Переносы строк, diff/statistics, indentation guards |
| `opencode_nvim/tool/lib/context.ts` | Старые adapters `metadata/ask`, разбор PermissionRejectedError; подлежит замене |
| `opencode_nvim/tool/*.txt` | Инструкции инструментам о review и ручных изменениях |
| `opencode_nvim/opencode.jsonc`, `scripts/install-tools.sh` | Установка конфигурации и tools в config dir Neovim |
| `lua/opencode/edit/state.lua`, `artifact/changes.lua` | Решения по файлам и фактическое применение со стороны Neovim |
| `ui/chat/edits.lua`, `edit_previews.lua`, `file_edit_results.lua`, `ui/native_diff.lua` | Review UX и история результатов |
| `tests/tools/neovim_apply_patch.test.ts`, `tests/tools/review.lua` | Сквозные TS → Lua проверки, в том числе пустых файлов, BOM и move |

Алгоритмы изменения файлов переписывать только при выявленном несовпадении. Основной перенос — регистрация, runtime, metadata/progress, запрос review и нормализация результата.

## 2. Точный API 2.0.11 и его ограничения

Источники: [Plugin API migration](https://opencode.ai/v2/docs/build/plugins/migrate-v1), опубликованные [ToolContext](https://unpkg.com/@opencode/plugin@2.0.11/dist/promise/tool.d.ts), [Tool schema](https://unpkg.com/@opencode/schema@2.0.11/dist/tool.d.ts), [Plugin.Context](https://unpkg.com/@opencode/plugin@2.0.11/dist/promise/plugin.d.ts).

### 2.1. Регистрация

V1 `export default tool({args,execute})` из `@opencode-ai/plugin` заменить на один bundled server plugin с устойчивым `id`, `setup(ctx)` и `ctx.tool.transform(editor => editor.add(...))`. Каждая tool definition имеет `name`, `description`, `input`, `execute`, optional `output`/`options`.

В Promise-ветке transform callback синхронный. Чтение description-файлов и другие I/O выполнить до регистрации. Имена инструментов сохранить, иначе потребуются изменения распознавания в Lua и описаний prompts.

Возможная структура будущего пакета:

```text
opencode_nvim/
  opencode.jsonc
  plugins/opencode-nvim/
    package.json
    index.ts
    rpc.ts
    tools/neovim_edit.ts
    tools/neovim_apply_patch.ts
    tools/rg.ts
    lib/review.ts
    lib/file_state.ts
    lib/text.ts
    lib/diff.ts
    descriptions/...
```

Это предлагаемый layout. До перемещения проверить правила загрузчика 2.0.11 и установку локальных зависимостей. Не оставлять одновременно v1 `tool/` и v2 plugin, регистрирующие дубли имён.

### 2.2. Execution context

Опубликованный Tool.Context содержит `sessionID`, `agent`, `messageID`, `id` (call ID), `progress`. В нём **нет** старых `directory`, `worktree`, `ask`, `metadata`.

- Контекст выполнения directory получать из `ctx.session.get({sessionID})` → `session.location.directory` и сохранять на время операции. `ctx.location` описывает место загрузки plugin, а не обязательно текущую session после move.
- Если display path требует project root/canonical, получить его из доступного подтверждённого контекста проекта; не считать directory и worktree синонимами. Абсолютный путь допустим как безопасный display fallback.
- `await context.progress(metadata)` — замена публикации progress для Promise tools. Передавать сами metadata; не старую оболочку `{title,metadata}`.
- Результат имеет `content?: string | Content[]`, optional `output` для объявленной схемы, `metadata`. Старый строковый `output` переносится в `content`; title при необходимости становится согласованным metadata.
- В проверенных опубликованных типах и adapter ToolContext отсутствует `signal`, несмотря на пример онлайн-документации. Нельзя строить cancellation исключительно на `context.signal`, пока R5 не докажет его наличие в выбранном runtime.

Для ожидающих review tools предпочтительна публичная **Effect-ветка** `@opencode/plugin/effect`: ожидание, finalizers и отмена привязываются к execution scope. Чистые файловые функции могут остаться Promise-функциями, вызванными через соответствующие Effect-обёртки. Реализацию писать против закреплённой версии Effect из зависимостей 2.0.11, а не копировать API Effect 3. Перед записью после ожидания проверить, что execution scope не отменён.

### 2.3. Почему нельзя просто заменить `context.ask()`

HTTP API действительно содержит `POST /api/session/{sid}/permission`. Однако plugin `PermissionDomain` 2.0.11 предоставляет `list/get/reply/hook`, **не `create`**. Plugin `SessionDomain` также не предоставляет вложенный `permission.create` или `form.create`. Полный сетевой `@opencode/client` и контекст plugin — не одинаковые поверхности API.

Поэтому основной план для custom diff review — собственный контракт через **официальный plugin RPC**. Не использовать вымышленный `ctx.session.permission.create`, приватный host context, поиск service password внутри tool или импорт внутренних Core-модулей.

Нативные permissions продолжают обслуживать стандартную политику доступа OpenCode. Собственный review отвечает за решения по конкретному diff. Это два разных механизма: глобальное `allow` на запуск инструмента не должно автоматически означать принятие каждого файла, а `deny` не должно обходиться собственным RPC.

## 3. Проектируемый контракт review RPC

Источник механизма: [Plugin RPC](https://opencode.ai/v2/docs/build/plugins/rpc/). Имена ниже — **новый API opencode.nvim**, а не встроенные методы OpenCode.

RPC definition `id="opencode_nvim"`, версия payload `protocolVersion=1`. Реализовать методы:

| Метод | Input | Output / назначение |
|---|---|---|
| `capabilities` | Пустой input | Версии plugin/protocol, поддержанные tools/review/todo возможности |
| `reviewList` | `sessionID?` | Pending reviews текущей location с IDs/revisions/context |
| `reviewGet` | `sessionID, reviewID` | Полный proposal или terminal status |
| `reviewReply` | `sessionID, reviewID, revision, decisions` | Подтверждённое settlement либо typed conflict/error |

Нативный transport RPC: `POST /api/rpc/{rpcID}/{method}` с `{input: ...}` и ответом `{output: ...}`. Передавать location по правилам RPC, если вызов должен попасть в конкретный экземпляр plugin. Не путать instance location для маршрута и execution directory session после move; capabilities/review должны хранить оба контекста.

Предлагаемые события `reviewCreated`, `reviewSettled`, `reviewCancelled` появятся во внешнем envelope как `rpc.opencode_nvim.<event>`. Подписчик обязан обрабатывать реальный envelope official RPC и фильтровать location. Схемы argument/result/event хранить в одном `rpc.ts`; Lua fixtures получать из этих схем и реальных ответов, не поддерживать две независимые спецификации.

### 3.1. Review record

Минимальные поля:

- `protocolVersion`, `reviewID`, `revision`, `status`, `created`;
- `sessionID`, `messageID`, `callID`, `tool`, `agent`, `directory`, routing location;
- стабильный `fileID` для каждого изменения; absolute path, display path, operation add/update/delete/move;
- before/after, proposed diff, BOM/EOL, existence и сведения об исходном/целевом пути move;
- metadata, достаточные для текущего native diff, без удаления значимых полей;
- aggregate outcome и отдельный outcome каждого файла после settlement.

`decisions` передаёт `fileID` и `accepted/rejected/resolved`, а не только «весь tool разрешён». Для manually resolved дополнительно определить подтверждение наблюдаемой версии файла; окончательной истиной остаётся повторное чтение диска серверным tool.

### 3.2. Идемпотентность и восстановление

- Один `(sessionID,callID)` создаёт один review; retry не создаёт дубли без новой execution generation.
- Повторный идентичный reply возвращает уже сохранённый outcome. Противоречащий reply или stale revision возвращает conflict и текущую запись.
- Невалидные file IDs, другой session ID и неактуальная revision не могут завершить ожидание.
- Клиент после reconnect сначала читает pending list, затем detail; SSE — уведомление, а не единственный источник proposal.
- In-memory ожидание нельзя сериализовать и оживить после рестарта plugin. Такие reviews помечаются cancelled/aborted; ни один файл не применяется после перезапуска только из сохранённого pending payload.
- Финальный результат хранится в native tool metadata/history; отдельное storage для diagnostics допустимо, но не должно расходиться с этим результатом.

## 4. Переход существующего Lua review на новый транспорт

1. Ввести tagged routing context review: `transport="permission"` для обычных server permissions и `transport="review_rpc"` для bundled diff review.
2. Не посылать `reviewID` на `/permission/.../reply`. Не добавлять custom review в нативный permission list как будто его создал OpenCode.
3. Добавить адаптер custom record → существующие `edit_state.add_edit` и file metadata. По возможности сохранить внутренний ID аргумент для UI; его название `permission_id` постепенно обобщить до `interaction_id` там, где иначе возможна путаница.
4. Все accept/reject/resolve действия по-прежнему проходят через `actions.lua` и edit owner.
5. Когда все файлы обработаны, отправить typed decisions через `reviewReply`; при ошибке не уничтожать локальный результат и не выполнять записи второй раз.
6. `reviewSettled` может прийти до HTTP callback. Применять одно terminal state transition.
7. Превью завершённых правок остаётся доступным после удаления pending interaction и смены session.
8. Danger mode, явно включённый в Neovim, использует тот же reviewReply с решениями по файлам либо согласованный путь «server apply all». Это отдельный подтверждённый режим, не вывод из отсутствия подключённого UI.

Нативная permission policy может запросить разрешение на запуск tool до custom review. Не подавлять её автоматическим `allow`. Проверить реальный порядок policy/hooks/execution в R4. Если требуется единый prompt UX, реализовать его только через подтверждённые публичные hooks без ослабления правил; до этого два этапа честно различаются как разрешение операции и review diff. Это открытый UX-риск, который надо закрыть до объявления полного сохранения поведения.

## 5. Файловый протокол исполнения

Текущий код допускает, что Neovim уже применил отдельные решения, пока tool ждёт. Этот путь нужно сохранить явно.

### 5.1. Подготовка

1. Получить execution directory и нормализовать пути, включая move destination.
2. Прочитать before-state: наличие, bytes/BOM/EOL/content.
3. Рассчитать after-state, diff и stats чистыми существующими функциями.
4. Проверить вход, наличие файлов, точное совпадение oldString и indentation constraints.
5. Опубликовать progress metadata с proposal; создать pending review, не меняя disk.
6. Зарегистрировать finalizer ожидания, чтобы interruption/reload/dispose снимал review и запрещал последующие записи.

### 5.2. Решение и применение

1. Neovim принимает/reject/resolves отдельные файлы по существующим правилам, сохраняя решения и ошибки записи.
2. Review reply завершает ожидание с конкретными file decisions.
3. Tool перечитывает фактический state всех путей.
4. Если файл уже равен принятому after-state — классифицировать как client-applied, не писать повторно.
5. Если manual content отличается от before и after — сохранить его и классифицировать как resolved/partial; не «исправлять» к предлагаемому after.
6. Если для explicit server-apply режима файл всё ещё равен before и разрешён — применить один раз, затем перечитать.
7. Если before изменился извне — не перезаписывать. Вернуть conflict/partial с фактическим diff.
8. Для rejected add не удалять существующий пустой/непустой файл, созданный пользователем во время ожидания. Сохранить защиту текущего `removeEmptyCreatedFile` и тестов.
9. Для mixed patch не применять общий patch второй раз. Каждый файл получает результат согласно решению и фактическому состоянию.
10. Учитывать write error отдельно от пользовательского reject; `approved` не означает `applied`.

Если нужен новый atomic multi-file apply, это самостоятельное расширение. Для миграции необходимо сохранить текущее честное отражение частичного результата, а не обещать транзакцию файловой системы.

### 5.3. Итоговый результат

Вернуть `content` с человеческим описанием и `metadata` с конечными `status`, `diff`, `files/filediff`, `proposed_diff`, additions/deletions, wrote/divergence по нуждам renderer. Status overall: applied/rejected/partial/failed, дополнительно cancelled при прерывании по согласованной схеме.

`final diff` вычисляется между original before и реальным disk после review. `proposed diff` сохраняется отдельно. Модель должна получить результат пользователя, а не первоначальный план инструмента. Существующие инструкции «не повторять rejected/partial без запроса пользователя» остаются в descriptions.

## 6. Перенос rg и runtime

`rg.ts` использует `Bun.spawn`; plugin v2 нельзя считать Bun-совместимым без runtime-проверки. Перейти на стандартный `node:child_process.spawn` либо другую подтверждённую public runtime API:

- сохранить argv-массив и `--`, не переходить к shell string;
- `cwd` задавать execution directory; текущий абсолютный search path не покрывает все relative arguments;
- обрабатывать exit 0/1/2, spawn error и отсутствие executable отдельно;
- одновременно читать stdout/stderr, избежать deadlock;
- сохранять limit результатов и ограничивать буфер, а не только резать гигантский вывод после чтения;
- interruption должен завершать дочерний процесс и ожидание; Effect finalizer — предпочтительный путь;
- вернуть `{content: text}` и структурированные metadata при необходимости;
- проверить glob, Unicode paths, pattern с ведущим `-`, несколько search roots и пустой результат.

Импорт `DESCRIPTION from "./file.txt"` тоже проверить в loader 2.0.11. Надёжный вариант — загрузка UTF-8 descriptions при setup или генерация TS-константы при сборке. Не читать/не загружать description заново при каждом tool call.

## 7. Установка, зависимости и todo extension

1. Закрепить `@opencode/plugin` и совместимые schema/protocol зависимости 2.0.11 в отдельном bundled package; не использовать плавающий `latest` при подготовке fixtures.
2. Проверить фактическую установку runtime dependencies локального plugin: обычный `cp` не гарантирует resolution импортов.
3. Изменить `scripts/install-tools.sh` так, чтобы управлять только собственными файлами/манифестом и не стирать чужие конфигурации. Удалять старые установленные v1 tools только после идентификации как принадлежащих плагину.
4. Сохранить пользовательские permissions и commands. Не переписывать весь global `opencode.jsonc` из bundled template.
5. Проверить `OPENCODE_CONFIG_DIR` private server и регистрацию через `plugins`; обнаружение `tool/` v1 не считать совместимым.
6. Через `capabilities` Lua проверяет нужный protocolVersion/tools до первого review. При несовместимости показать понятную инструкцию установки, а не ждать несуществующий permission event.
7. Если R6 требует собственного todo-хранилища, расширить **тот же versioned RPC** методами todoGet/todoSet и invalidation event; storage разделяется по session и location. Изменение todo из tool публикуется и сохраняется атомарно относительно собственного version counter. Не выдавать эти методы за native OpenCode API.

## 8. Проверки

Существующий `tests/tools/neovim_apply_patch.test.ts` mock-ает `@opencode-ai/plugin`; после миграции такой зелёный тест ничего не доказывает о загрузке v2. Разделить чистое ядро и контрактные тесты регистрации.

| Группа | Сценарии |
|---|---|
| Registration | Чистая установка, ровно три effective tool names, schemas, description, reload без дублей |
| RPC | Capabilities/version mismatch, list/detail, repeat reply, conflicting revision, неправильные session/file IDs |
| Edit | Замена одна/все, отсутствующий oldString, indentation guard, пустой файл, add |
| Patch | Add/update/delete/move, several files, source/destination already changed, пустой patch |
| Review | Все accept, все reject, mixed, manual resolve, ручная правка во время ожидания |
| Bytes | BOM, CRLF/LF, финальный newline, Unicode paths/content |
| Failures | Ошибка чтения/записи, partial apply, UI отключён, reply потерян, plugin reload, session interrupt |
| Races | Reply до callback, два клиента отвечают одновременно, повторное событие, устаревший review после reset |
| rg | Exit 0/1/2, missing binary, большие stdout/stderr, отмена процесса, argv escaping |
| Recovery | Reconnect во время review, чтение финального tool metadata из history после повторного открытия |

Сохранить существующий TS → headless Neovim harness с настоящими файловыми действиями Lua. Добавить регистрацию через реальный v2 API и интеграционный прогон tools сервером 2.0.11. Unit mock допускается для изолированной бизнес-логики, но не заменяет этот gate.

Особое требование: test interruption ставит исполнение на ожидание review, прерывает session, затем доставляет поздний reply. После этого bytes всех файлов должны совпасть с состоянием до позднего reply; ни один Promise continuation не должен продолжить запись.

## 9. Критерии готовности

- [x] Старый `@opencode-ai/plugin`, `context.ask/metadata`, незафиксированные Bun runtime assumptions удалены из v2-пути.
- [x] Plugin грузится чистой установкой и публикует capabilities.
- [x] Review реализован через публичный API, без вымышленных методов Plugin.Context.
- [x] Стандартные permissions не обходятся; закрыт UX-вопрос native gate + diff review.
- [x] Принятие/отклонение/ручной resolve по каждому файлу сохраняют текущую функциональность.
- [x] R4/R5 закрыты, interruption и late reply не вызывают запись после отмены.
- [x] Final metadata соответствует реальному disk, а не первоначальному proposal.
- [x] Повторный HTTP/event не приводит к повторному применению.
- [x] Todo extension реализовано, если оно необходимо по R6.
- [x] Existing file-safety tests и real-server registration/execution tests проходят.

Это более крупная работа, чем замена import: ограничение Plugin.Context 2.0.11 делает отдельный review protocol важной частью оценки объёма.
