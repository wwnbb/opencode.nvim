---

### 3. `lua/opencode/edit/state.lua:accept_all()` / `reject_all()`

**Почему:** batch accept/reject игнорируют ошибки `changes.accept()` / `changes.reject()`. Danger mode может approve server-side даже если локальное применение файла не удалось.
**Нужно:** агрегировать ошибки, менять file status только после успешной операции.
**Confidence:** high.

---

### 4. `lua/opencode/events/handlers/permission.lua:M.setup()`

**Почему:** ~593 строки, внутри permission event callback ~300+ строк. Смешаны permission routing, edit normalization, artifact creation, spinner, cleanup, danger mode.
**Нужно:** вынести normalizers, edit permission flow, non-edit permission flow, reply/cleanup handlers.
**Confidence:** high.

---

### 5. `lua/opencode/init.lua:M.send()`

**Почему:** ~353 строки, nested `send_with_session()` ~300 строк. Смешаны session creation, payload build, sync seeding, async/sync send, timers, error handling.
**Нужно:** extract `build_payload`, `seed_local_message`, `sync_session_messages`, `handle_send_error`, `send_existing_session`.
**Confidence:** high.

---

### 6. Chat tool renderers: `bash/read/search/rg/skill/todos`

**Почему:** много повторов: panel helpers, folded/expanded logic, overflow text, anim frames, input merging. Плюс dead wrappers вроде твоего примера.
**Файлы:**
- `lua/opencode/ui/chat/bash.lua`
- `read.lua`
- `search.lua`
- `rg.lua`
- `skill.lua`
- `todos.lua`

**Нужно:** общий `tool_panel.lua` / helper в `render.lua`: input merge, overflow, header, body rendering.
**Confidence:** high.

---

### 7. Widget rerender / tracked line replacement

**Почему:** `questions.lua`, `permissions.lua`, `edits.lua`, `tasks.lua` вручную делают похожие `buf_set_lines`, clear namespace, apply highlights, shift tracked ranges.
**Нужно:** общий `widget_support.replace_block()` или аналог.
**Evidence:**
- `questions.lua:220`
- `permissions.lua:168`
- `edits.lua:677`
- `tasks.lua:1237`

**Confidence:** high.

---

### 8. `lua/opencode/ui/float.lua`

**Почему:** три разные menu systems в одном файле:
- `create_menu()` ~173 строки
- `create_searchable_menu()` ~389 строк
- `create_session_list()` ~231 строк

Повторяются popup lifecycle, close handling, keymaps, filtering/rendering.
**Нужно:** общий menu controller/list controller.
**Confidence:** high.

---

### 9. `lua/opencode/ui/input.lua:M.show()`

**Почему:** ~311 строк, смешаны layout, popup creation, autocmds, info bar, history, pending text restore. Ещё найден bug: `M.setup()` пишет `opts.max_history` в `defaults.max_entries`, а trimming читает `history.max_entries`.
**Нужно:** разделить layout/popups/autocmds/info bar/history; поправить ownership `max_history`.
**Confidence:** high.

---
