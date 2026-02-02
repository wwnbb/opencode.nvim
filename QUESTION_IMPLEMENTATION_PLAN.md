# OpenCode.nvim Question Tool Implementation Plan

## Overview
Implement full interactive question tool support for OpenCode.nvim, displaying questions inline in the chat buffer (not as a popup) with keyboard navigation and selection.

## Constraint
**IMPORTANT:** Question must be displayed IN the chat buffer, not in a popup window. User interaction happens within the chat interface, similar to regular message flow.

---

## Architecture

### Display Strategy
Questions render as an **inline interactive widget** within the chat buffer:
- Displayed as a special message type between regular messages
- Visual styling distinguishes it from regular chat content
- Interactive elements (options) are keyboard-navigable
- Selection state is visually indicated (highlighting, markers)

### Interaction Flow
1. Question appears inline in chat when `question.asked` event received
2. User navigates options with `↑↓` or number keys `1-9`
3. Visual indicator shows currently selected option
4. `Enter` confirms selection, `Esc` cancels
5. Answer sent via API, question updates to show answered state
6. Assistant continues with workflow

---

## Implementation Tasks

### Phase 1: Core Infrastructure (2-3 hours)

#### Task 1.1: Create Question State Module
**File:** `lua/opencode/question/state.lua` (NEW)

**Responsibilities:**
- Store active questions by session ID and request ID
- Track selection state (current tab, selected options, custom input)
- Provide getter/setter for question state
- Handle multiple questions per request (tabs)

**Key Functions:**
```lua
M.add_question(request_id, session_id, questions_data)
M.get_question(request_id)
M.update_selection(request_id, tab_index, selected_options)
M.set_custom_input(request_id, tab_index, text)
M.remove_question(request_id)
M.get_all_active()
```

**Dependencies:** None

---

#### Task 1.2: Extend HTTP Client for Question API
**File:** `lua/opencode/client/init.lua` (MODIFY)

**Add Functions:**
```lua
-- Reply to a question with selected answers
M.reply_to_question(session_id, request_id, answers)
-- answers: array of arrays, e.g., {{"README.md"}, {"option2"}}

-- Reject/cancel a question
M.reject_question(session_id, request_id)
```

**API Endpoints:**
- POST `/sessions/{sessionID}/question/reply`
- POST `/sessions/{sessionID}/question/reject`

**Dependencies:** Task 1.1

---

#### Task 1.3: Handle Question Events
**File:** `lua/opencode/events.lua` (MODIFY)

**Add Event Handlers:**
- `question.asked` → Store question, trigger UI update
- `question.replied` → Remove question, mark as answered
- `question.rejected` → Remove question, mark as rejected

**Integration:**
- Emit custom event `question_pending` when question needs answer
- Emit `question_answered` when question is resolved

**Dependencies:** Task 1.1, Task 1.2

---

### Phase 2: UI Widget Implementation (3-4 hours)

#### Task 2.1: Create Question Widget Module
**File:** `lua/opencode/ui/question_widget.lua` (NEW)

**Responsibilities:**
- Render question inline in chat buffer
- Format question with header, question text, options
- Visual indicators for selection state
- Support for multiple tabs (multiple questions)
- Support for custom input field
- Multi-select checkboxes visualization

**Rendering Format:**
```
💭 Question [req_abc123]                    09:33
────────────────────────────────────────────
File to edit/review

Which file would you like me to open?

❯ 1. README.md
  2. init.lua
  3. lua/opencode/init.lua
  4. Provide custom path

[↑↓ navigate, 1-4 select, Enter confirm, Esc cancel]
```

**Key Functions:**
```lua
M.render_question(request_id, question_data, current_selection)
M.get_lines_for_question(request_id) → returns formatted lines
M.apply_highlights(bufnr, start_line, question_data, selection)
M.get_option_count(question_data) → number of selectable options
```

**Dependencies:** Task 1.1

---

#### Task 2.2: Chat Buffer Integration
**File:** `lua/opencode/ui/chat.lua` (MODIFY)

**Changes:**
- Modify `render_message()` to check for question type
- Add question rendering between header and content
- Track line ranges for each question (for highlighting)
- Store question metadata in message struct

**New Message Type:**
```lua
{
  role = "system",
  type = "question",
  request_id = "req_xxx",
  questions = {...},
  status = "pending" | "answered" | "rejected"
}
```

**Dependencies:** Task 2.1

---

#### Task 2.3: Interactive Navigation System
**File:** `lua/opencode/ui/chat.lua` (MODIFY)

**Keymaps (only active when cursor on question):**
- `↑` / `k` → Move selection up
- `↓` / `j` → Move selection down  
- `1-9` → Jump to option by number
- `Enter` → Confirm current selection
- `Esc` → Cancel/reject question
- `Tab` → Next tab (if multiple questions)
- `Shift+Tab` → Previous tab

**Implementation:**
- Add buffer-local keymaps for question navigation
- Check if cursor is on a question line before handling
- Update question state and re-render

**Dependencies:** Task 2.2

---

### Phase 3: Selection & Response Flow (2-3 hours)

#### Task 3.1: Selection State Management
**File:** `lua/opencode/question/state.lua` (MODIFY)

**Add Selection Logic:**
```lua
M.select_option(request_id, option_index)
M.toggle_multi_select(request_id, option_index) -- for multi-select
M.move_selection(request_id, direction) -- up/down
M.get_current_selection(request_id) → current option index
M.set_tab(request_id, tab_index)
```

**Selection Types:**
- Single select: Only one option selected at a time
- Multi-select: Multiple options can be toggled
- Custom input: Text input for "other" option

**Dependencies:** Task 1.1

---

#### Task 3.2: Answer Submission
**File:** `lua/opencode/ui/chat.lua` (MODIFY)

**Submit Handler:**
1. Get current question at cursor
2. Collect selected answers from all tabs
3. Format as `answers` array
4. Call `client.reply_to_question()`
5. Update question status to "answered"
6. Re-render to show completed state

**Visual Feedback:**
- Show "Submitting..." briefly
- Update question display to show selected answer
- Change styling to indicate completed

**Dependencies:** Task 1.2, Task 2.3, Task 3.1

---

#### Task 3.3: Cancel/Reject Handler
**File:** `lua/opencode/ui/chat.lua` (MODIFY)

**Cancel Handler:**
1. Get current question at cursor
2. Call `client.reject_question()`
3. Update question status to "rejected"
4. Re-render with rejection styling

**Dependencies:** Task 1.2, Task 2.3

---

### Phase 4: Multi-Question & Advanced Features (2-3 hours)

#### Task 4.1: Multi-Tab Support
**File:** `lua/opencode/ui/question_widget.lua` (MODIFY)

**Features:**
- Render tab bar when multiple questions in request
- Show active tab indicator
- Tab labels from question headers
- "Confirm" tab for final review

**Render Format:**
```
💭 Question [req_abc123]                    09:33
────────────────────────────────────────────
[File to edit] [Another question] [Confirm]

File to edit/review
❯ 1. README.md
  2. init.lua
  
[↑↓ navigate, Tab switch tab, Enter confirm]
```

**Dependencies:** Task 2.1

---

#### Task 4.2: Custom Input Support
**File:** `lua/opencode/ui/question_widget.lua` (MODIFY)

**Features:**
- "Type your own answer" option
- When selected, show input prompt
- Capture user text input
- Store as answer

**Integration:**
- Use existing input.lua for text capture
- Or inline edit mode within question

**Dependencies:** Task 2.1, Task 3.1

---

#### Task 4.3: Answered State Display
**File:** `lua/opencode/ui/question_widget.lua` (MODIFY)

**Completed Question Format:**
```
✓ Question [req_abc123]                     09:33
────────────────────────────────────────────
File to edit/review: README.md

Answered: README.md
```

**Features:**
- Different icon (✓ vs 💭)
- Show selected answer(s)
- No interactive elements
- Collapsible like other tools

**Dependencies:** Task 2.1

---

### Phase 5: Configuration & Polish (1-2 hours)

#### Task 5.1: Add Configuration Options
**File:** `lua/opencode/config.lua` (MODIFY)

```lua
question = {
  enabled = true,
  icon_pending = "💭",
  icon_answered = "✓",
  icon_rejected = "✗",
  highlight_header = "Title",
  highlight_selected = "CursorLine",
  highlight_option = "Normal",
  max_height = 10,
  show_keymap_hint = true,
  auto_focus = true, -- auto-focus on new question
}
```

**Dependencies:** None

---

#### Task 5.2: Help Documentation Update
**File:** `lua/opencode/ui/chat.lua` (MODIFY - help function)

**Add to Help Text:**
```
Question Tool:
  1-9      - Select option by number
  ↑/↓ j/k  - Navigate options
  Enter    - Confirm selection
  Esc      - Cancel question
  Tab      - Next question tab
```

**Dependencies:** Task 2.3

---

#### Task 5.3: Testing & Debugging
**Files:** All modified files

**Test Scenarios:**
1. Single question with single-select options
2. Multi-select question (multiple answers)
3. Question with custom text input
4. Multiple questions (tabs)
5. Answering question (verify API call)
6. Canceling question (verify reject)
7. Navigation with keyboard
8. Number key quick selection

**Debug Features:**
- Add request_id to display for debugging
- Log question state changes
- Log API requests/responses

**Dependencies:** All previous tasks

---

## File Structure

```
lua/opencode/
├── question/
│   └── state.lua          (NEW) Question state management
├── ui/
│   ├── chat.lua           (MODIFY) Integrate questions into chat
│   └── question_widget.lua (NEW) Question rendering
├── client/
│   └── init.lua           (MODIFY) Add question API
└── events.lua             (MODIFY) Handle question events
```

---

## Timeline

**Total Estimated Time:** 10-15 hours

- Phase 1: 2-3 hours (Core infrastructure)
- Phase 2: 3-4 hours (UI widget)
- Phase 3: 2-3 hours (Selection & response)
- Phase 4: 2-3 hours (Advanced features)
- Phase 5: 1-2 hours (Configuration & testing)

**Priority Order:**
1. Tasks 1.1, 1.2, 1.3 (Foundation)
2. Tasks 2.1, 2.2 (Basic display)
3. Tasks 2.3, 3.1, 3.2 (Interaction)
4. Tasks 3.3, 4.1, 4.2, 4.3 (Completion)
5. Tasks 5.1, 5.2, 5.3 (Polish)

---

## Key Design Decisions

### Why Inline vs Popup?
- More consistent with chat experience
- User can see question in context of conversation
- No interruption to workflow
- Easier to reference previous messages while answering

### Why Stateful Approach?
- Questions can have complex state (multi-select, tabs)
- Need to track selection across re-renders
- Support for multiple simultaneous questions
- Clean separation between data and presentation

### Keyboard Navigation Philosophy
- Match vim patterns (↑↓ j/k)
- Numbers for quick access (1-9)
- Enter/Esc for confirm/cancel (standard)
- Tab for tabs (conventional)

---

## Success Criteria

- [ ] Questions display inline in chat buffer
- [ ] Options are keyboard-navigable
- [ ] Selection state is visually clear
- [ ] Enter submits answer to server
- [ ] Esc cancels/rejects question
- [ ] Multi-question tabs work
- [ ] Multi-select works
- [ ] Custom input works
- [ ] Answered questions show answers
- [ ] Help text updated

---

## Risk Mitigation

**Risk 1: Complex buffer management**
- Mitigation: Clear line tracking, store metadata per question

**Risk 2: Race conditions with streaming**
- Mitigation: Throttle updates, queue state changes

**Risk 3: Focus management**
- Mitigation: Only enable keymaps when cursor on question

**Risk 4: Multiple simultaneous questions**
- Mitigation: Queue questions, show one at a time or use tabs
