# 07. Интерфейс и сквозная проверка

Итог: реализовано и проверено; [сверка критериев и ограничения](FINAL-VALIDATION.md).

Цель: сохранить привычный интерфейс opencode.nvim после миграции на **OpenCode 2.0.11**, корректно отобразить новые состояния и доказать работоспособность всей пользовательской цепочки.

Зависимости: все [планы 1–6](README.md). UI можно адаптировать постепенно на fixtures, но итоговая готовность проверяется с реальным сервером и установленными bundled tools.

## 1. Что переиспользовать

Сохраняются nui.nvim, окно чата, input, layouts vertical/horizontal/float, session tabs, palette/menu/float helpers, highlight groups, native diff и существующие пользовательские команды. Их переписывание не требуется из-за нового HTTP API.

Основной способ сохранить UI — передавать в него нормализованные данные через selectors/sync. HTTP DTO v2 не должны проникать в каждый widget и keymap callback.

Правила [AGENTS.md](../../AGENTS.md) остаются обязательными:

- UI вызывает `actions.lua`, а не `init.lua` или HTTP напрямую;
- tool/widget output использует `render.add_panel_line()` / `add_panel_raw_line()`;
- ширина берётся из `render.get_chat_text_width()`;
- extmarks используют существующий namespace и established OpenCode highlights;
- изменения buffer происходят в main loop;
- view state хранит позиции/expanded/cursor, domain state — у своих владельцев.

## 2. Карта адаптации UI

| Модуль | Изменение | Что проверить |
|---|---|---|
| `ui/chat/init.lua`, `session_tabs.lua` | Session location, background activity, invalidated/deleted sessions | Вкладки не исчезают от частичного snapshot |
| `message_renderer.lua`, `messages.lua` | Новые служебные message types и content order | История и live отображаются одинаково |
| `processing_footer.lua`, `task_animation.lua` | Admission/queued/execution/retry/interaction разделены | Нет вечного spinner и ложного завершения |
| `tool_renderer.lua`, `tool_labels.lua`, `tool_panel.lua` | Native tool name, structured content/error, time mapping | Длительность и вывод не теряются |
| `bash.lua`, `read.lua`, `rg.lua`, `search.lua`, `skill.lua` | Нормализованные input/output/metadata v2 | Большой/пустой/ошибочный результат |
| `tasks.lua`, `task_children.lua`, `nav.lua` | Фоновые child sessions, namespaced tool classification | `gd`/`<BS>` ведут в правильную session |
| `todos.lua` | Источник состояния после решения R6 | Dock восстанавливается после reconnect |
| `permissions.lua`, `questions.lua`, `interactions.lua` | Typed forms, native permissions и review RPC | Действие адресуется текущему widget, а не глобальному последнему request |
| `edits.lua`, `edit_previews.lua`, `file_edit_results.lua` | Новый review transport, сохранённые final/proposed diff | Принятие/отклонение/manual, просмотр после завершения |
| `cursor.lua`, `widget_index.lua`, `widget_support.lua` | Stable identity и content reordering | Позиция не прыгает при новой delta/history load |
| `render_coordinator.lua`, `render_context.lua`, `render_state.lua` | Инвалидация по новым revisions | Один update не вызывает полную перерисовку каждого token |
| `ui/input/*` | Typed attachments, selection, validation feedback | Ввод/история не очищаются при failed send |
| `ui/palette/*`, `ui/active_sessions.lua` | Новые catalogs/auth/status/session operations | Устаревшие пункты не показывают ложный success |
| `components/lualine.lua` | Фактический active/queued/retry/interaction state | Нет работы в другой session под текущей подписью |
| `help.lua`, `commands.lua`, `README.md` | Новые пояснения и установка | Команды/клавиши совпадают с кодом |

## 3. Состояния, видимые пользователю

### 3.1. Отправка и исполнение

Показывать понятные состояния «отправляется», «в очереди», «выполняется», «ожидает ответа», «восстанавливается соединение», «ошибка отправки». Эти подписи относятся к разным фактам, даже если некоторые объединены визуально в одной status line.

- Принятый prompt остаётся видимым во время очереди.
- Ожидание permission/form/review прекращает бессмысленную анимацию генерации, но не объявляет session завершённой.
- `step.ended` с tool calls не скрывает признак работающей session.
- При reconnect не вставлять пользователю новые фальшивые сообщения о каждом запросе recovery.
- Неопределённый outcome имеет объяснимый статус и способ повторной проверки; UI не предлагает повторить платный запрос как будто точно ничего не произошло.
- Model/agent подпись ответа берётся из его исторических данных. Новая локальная настройка не меняет уже отрисованный ответ.

### 3.2. Новые типы истории

Agent/model/location switch показывать компактными служебными строками. Skill/shell/compaction имеют свой отображаемый смысл. Synthetic/system сообщения не выдаются за пользовательский текст.

Unknown native message/tool type должен иметь безопасное generic representation и diagnostic log. Сериализация table в `table: 0x...` недопустима. Детали внутреннего протокола не показывать в обычном пользовательском потоке, если они не помогают исправить проблему.

### 3.3. Формы

Сохранить selection по `field.key`, не по позиции. Для options хранить value отдельно от label. Boolean/number/integer требуют собственных controls/validation. При server error оставлять введённые данные и выделять проблемное поле.

External field открывает указанную ссылку только действием пользователя и показывает ожидание фактического завершения. Нельзя закрыть форму локальным «Готово», если сервер ещё считает её pending.

Для формы без message/tool linkage использовать session-level widget. Смена активной session не отправляет её answer в новый session ID.

### 3.4. Review файлов

Виджет получает общий внутренний interaction context с тегом transport. Пользователь продолжает принимать, отклонять и вручную изменять файлы существующими действиями.

Сохранять отдельно proposal и фактический результат. После mixed/manual review показать статус каждого файла. Повторное открытие native diff не повторяет применение и не меняет readonly result view в pending review.

Если стандартная permission policy и custom review RPC дают два этапа, UI должен объяснять их назначение. Закрытие этого UX-расхождения — совместная задача с планом 5; нельзя считать её выполненной только по красивому screenshot виджета.

## 4. Клавиши и навигация

Проверять фактически установленные mappings из `config.lua`/`ui/chat/keymaps.lua`; таблица ниже описывает стандартный профиль из текущего проекта.

| Клавиши/действие | Проверка после переноса |
|---|---|
| `q`, `i` | Закрытие/возврат input не отменяют серверную session сами по себе |
| `<C-g>`, `<C-x><C-s>` | Один submit на действие, корректный pending state |
| `<C-c>` | Interrupt правильной session; очередь обрабатывается по явной политике |
| `N`, `x`, `gt`, `gT`, числовой выбор вкладки | Создание/закрытие/переключение без потери чужих session данных |
| `O` | Expanded state сохраняется при snapshot и final content replacement |
| `gd`, `<BS>` | Правильный child/parent даже при фоновых задачах с одинаковыми именами |
| `T` | Todo dock использует восстановленный источник состояния |
| `j/k`, `<CR>`, `<Space>`, `1–9`, `<Tab>/<S-Tab>` | Выбор options/form fields адресуется widget под курсором |
| `<C-a>/<C-x>/<C-m>`, `A/X/M` | Per-file/all review работает с новым транспортом и не пишет дважды |
| `=`, `dt`, `dv` | Inline/native diff, правильный focus/возврат в chat |
| `<C-t>`, `<C-a>`, `<C-e>` в input | Variant/agent/model меняются в корректном контексте |
| `a`, `[a`/`]a`, `[m`/`]m`, `[p`/`]p` | Auto-scroll и navigation используют новые boundaries/positions |
| `<C-p>`, `?` | Palette/help соответствуют поддерживаемым v2 действиям |

Проверить конфликты normal/insert mode и терминальных кодов `<CR>`/`<C-m>`. Миграция не должна добавлять непроверенный второй binding на тот же keycode.

## 5. Render и производительность

1. Входящие события меняют domain state, затем один render request; transport не вызывает полную перерисовку напрямую.
2. Сохранить batching/coalescing и revision-based invalidation. Один progress update tool не пересобирает все другие sessions.
3. Нормализацию больших content/metadata делать один раз при commit, не на каждом cursor move.
4. Изменение terminal part обновляет message revision и очищает stale widget positions.
5. Cursor capture/restore использует identity, а не только старый номер строки.
6. Auto-scroll отключённый пользователем не включается после reconnect/history load.
7. Ограничить память буфера orphan events/recovery и диагностировать overflow. Не терять событие молча ради скорости.
8. Измерить количество render calls и задержку input на fixture с длинным ответом и множеством small deltas. Зафиксировать baseline до изменения; критерий — отсутствие существенной регрессии относительно этого baseline, а не произвольное обещание миллисекунд.

## 6. Детерминированная проверка без сервера

Fixtures v2 должны покрыть полную историю: user → reasoning → text → tools → form/permission/review → continuation → idle. Для каждой последовательности сохранить HTTP-equivalent финальный snapshot.

Проверять:

- `live events → sync → rendered lines` эквивалентно `HTTP history → sync → rendered lines`;
- semantic data и widget identity, а не только отсутствие Lua exception;
- trailing/blank lines, wrapping, Unicode widths и structured errors;
- menu state при обновлении catalogs;
- focus и cursor после формы, popup, native diff и window close;
- reset/cleanup без оставшихся timers, autocmds и invalid buffer references.

Существующие наборы:

```sh
./tests/run.sh unit
./tests/run.sh checks
./tests/run.sh integration
./tests/run.sh smoke
./tests/run.sh tools
```

Особенно важны `tests/integration/chat_tabs_spec.lua`, `chat_winclosed_spec.lua`, `chat_render_freshness_spec.lua`, `tests/smoke/thinking_render_spec.lua`, `chat_new_session_skill_render_spec.lua`, `tests/checks/architecture_spec.lua`, `state_ownership_spec.lua`.

Архитектурные проверки обновляются для новых адаптеров, но не ослабляются, чтобы пропустить прямые UI → state/HTTP вызовы. Новые tests должны проверять поведение на неоднозначных входах, а не повторять реализацию строка в строку.

## 7. Сквозной прогон с реальным OpenCode 2.0.11

### 7.1. Изолированный профиль

Создать отдельные временные project/config/data/state directories; использовать проверенные R1 env/CLI настройки из плана 1. Не рассчитывать, что `OPENCODE_CONFIG_DIR` сам изолирует всю database/state. Сначала выяснить фактические пути через поддерживаемые debug команды, затем убедиться, что smoke использует только тестовый профиль.

Установить ровно целевую CLI и bundled plugin, сохранить version outputs. Настроить один тестовый provider для коротких реальных запросов. Fixtures и logs обезличить. Способ запуска записать в будущий тестовый script; пока script не существует, не выдавать его команду за готовую.

### 7.2. Матрица пользовательских сценариев

| № | Действия | Успешный результат / доказательство |
|---|---|---|
| E01 | Первый toggle, автозапуск, открыть input | Версия/состояние корректны, один процесс и одна SSE-подписка |
| E02 | Отправить короткий текст, дождаться ответа | Один user/assistant, поток виден, финальный текст совпал с history |
| E03 | Поменять agent/model/variant, отправить | Сервер использовал правильный selection; подписи совпадают |
| E04 | Файл, выделение, image clipboard, agent/skill mentions | Сервер получил правильные attachments, reload их сохранил |
| E05 | Отправка во время busy согласно выбранной политике | Блокировка/queue/steer отражает реальное действие, без скрытого дублирования |
| E06 | Interrupt и отмена queued input | Только нужная операция прекращена, UI не остаётся busy навсегда |
| E07 | Ответить на permission once/always/reject | Решение дошло до нужной session; save semantics корректны |
| E08 | Формы всех типов, conditional/external fields | Values и validation проходят round-trip, чужой ответ отображается |
| E09 | `neovim_edit`: accept/reject/manual | Файлы и final metadata совпадают с решениями |
| E10 | Multi-file patch: add/update/delete/move, mixed решения | Ручные изменения/BOM/EOL сохранены, повторного apply нет |
| E11 | `rg`: совпадения, нет совпадений, error, отмена | Вывод, статус и дочерний процесс корректны |
| E12 | Несколько subagents, перейти `gd` и вернуться | Правильное дерево; background child продолжает обновляться |
| E13 | Todo создать/обновить, закрыть и открыть chat | Dock восстановлен из серверного источника |
| E14 | Разорвать SSE в середине text/tool/review, восстановить | Итог совпал с сервером, pending interactions и cursor восстановлены |
| E15 | Переключить три sessions из разных directories во время запросов | Нет чужих сообщений, permissions, catalogs или ошибок во вкладке |
| E16 | Fork, compact, diff, stage/clear/commit revert | Границы history и файлов соответствуют действию |
| E17 | Key/OAuth auth, переключить/удалить выбранный account | Models обновлены, чужие credentials и pending forms не затронуты |
| E18 | MCP connect/disconnect/needs-auth | UI показывает подтверждённый статус |
| E19 | Restart собственного server, reconnect к внешнему, reload | Правильное владение процессом; recovery, cancellation и version checks работают |
| E20 | Удалить session с children во время callbacks | Нет воскрешения вкладок и orphan state |
| E21 | Повторно открыть завершённую историю в чистом Neovim | Tool results, forms/review summaries и order доступны |
| E22 | Неподдерживаемая version / старый bundled plugin | Понятная ошибка и инструкция; нет частично работающего silent fallback |

Для E09/E10/E14 сохранять before/after bytes и tree файлов. Для E02/E04/E12/E16/E21 — final HTTP snapshots и соответствующие UI результаты. Для E17 не сохранять ключи/codes/tokens в доказательствах.

## 8. Визуальная проверка

Снять baseline до реализации и результат после неё для одинаковой ширины/темы/fixture:

1. Обычный ответ с markdown, reasoning и длинными строками.
2. Tool running/success/error, многострочный output.
3. Pending permission и typed form с несколькими полями.
4. Multi-file review и native diff, final readonly result.
5. Несколько session tabs, active/background child, todo dock.
6. Palette выбора модели и integration auth status.

Проверить минимум узкую и широкую раскладку, vertical/horizontal/float, resize, скрытие/показ окна, смену темы. Screenshots подтверждают layout; они не заменяют проверки RPC, file writes и event recovery.

## 9. Выпуск и переход пользователя

1. README указывает минимально проверенную CLI 2.0.11 и установку нового server plugin.
2. Config examples соответствуют существующему `setup()` и выбранному способу server startup.
3. Описать переход со старого bundled `tool/` и версию review RPC; обновление Lua без server plugin не должно выглядеть как успешная установка.
4. Сохранить предыдущий выпуск для v1 и инструкцию возврата конфигурации. Не обещать downgrade server database через откат Lua-плагина.
5. Известные ограничения описать предметно: например support remote attachments/TLS или отсутствующий runtime LSP. Не прикрывать ошибку пустым widget.
6. После полного зелёного прогона не повторять те же tests без причины; новую проверку запускать после изменения, найденной ошибки или незакрытого риска.

## 10. Итоговые критерии готовности

- [x] Все пункты E01–E22 выполнены либо доказано, что конкретный пункт не входит в существующие возможности, с явным описанием причины; существующую функцию нельзя исключить ради зелёного отчёта.
- [x] UI остаётся пригодным с клавиатуры, focus/cursor устойчивы к streaming и recovery.
- [x] Стандартные keymaps и пользовательская конфигурация работают.
- [x] Нативные данные v2 не потребовали обхода actions/state ownership.
- [x] Live и cold-history render семантически эквивалентны.
- [x] Review сохраняет реальные bytes и пользовательские ручные изменения.
- [x] Формы/permissions/background tasks/todo корректны после reconnect.
- [x] Performance не имеет подтверждённой существенной регрессии.
- [x] Полный набор необходимых tests и чистая установка прошли.
- [x] README/help/status отражают реально поддержанные возможности.

Миграция считается завершённой по совокупности этих доказательств и критериев планов 1–6, а не по одному успешно полученному текстовому ответу.
