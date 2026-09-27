# opencode.nvim
<img width="1512" height="982" alt="Screenshot 2026-06-14 at 17 36 33" src="https://github.com/user-attachments/assets/6430607d-fa84-46b4-802f-d419a44701f9" />

opencode.nvim is a Neovim frontend for [OpenCode](https://github.com/sst/opencode), the open-source AI coding agent.

The plugin brings OpenCode into Neovim through an editor-native interface, with all widgets implemented in Lua.
Its chat UI, input area, session tabs, and status elements are designed to feel like part of Neovim rather than a separate terminal experience.

opencode.nvim supports multiple OpenCode sessions in a single Neovim instance.
This allows different conversations to stay active at the same time, making it easier to move between tasks,
projects, and prompts without leaving the editor.

The goal of opencode.nvim is to make OpenCode feel lightweight, scriptable, keyboard-friendly,
and naturally integrated into the Neovim workflow.

# Thought and Explore

Reasoning appears as a collapsed `+ Thought · 216ms` row. Press `O` or `Enter`
on it to show the full reasoning behind a left border. Consecutive reasoning
parts share a row, with their step count and combined duration.

Consecutive Read, Glob, and Grep calls appear as `→ Explored — 1 read, 2 searches`.
Expand the row to see file paths and search summaries. Active groups animate as
`Thinking` or `Exploring`; failures remain visible when collapsed, and permission
requests stay accessible. Expansion is preserved while streaming. Set `thinking.enabled = false` to hide reasoning.

# Execute / MCP tools

Consecutive `execute` invocations share a compact `→ Executed — 3 calls` row,
following the Explore interaction. Press `O` or `Enter` to show one line per
invocation, then expand an individual line to see its MCP calls.
Active groups show `Executing`; failed and cancelled invocations stay
discoverable when the group is collapsed. Collapsing a group also closes its
children.

Explore, Execute, and Web share the same group renderer, status rules, error visibility,
navigation, and expansion state. Their declarations in
`lua/opencode/ui/chat/tool_group.lua` supply the labels, tool membership, count
labels, and leaf renderer. Detailed tool widgets keep their own content.

The expanded widget shows only its header and MCP calls on the chat background,
without a panel frame or fill. It works with any MCP server.

Press `Enter` on a recorded call to open the read-only inspector. The
inspector replaces the chat content, with tabs in its top navigation. There,
`1` shows the readable result, `2` the original raw output, `3` the
script, and `4` the calls and their inputs. Normal search, scroll, and yank work;
`Tab` switches tabs; `q`, `Esc`, or `Backspace` returns to the chat. JSON strings
are decoded for the readable view, while Raw retains the original output.
The result belongs to the whole script.

# Web search and fetch

Consecutive `websearch` and `webfetch` requests share a compact
`→ Browsed — 1 search, 2 fetches` row. Active requests show `Browsing` with one
spinner for the group. Press `O` or `Enter` to list requests, then expand a
request to read its response. Collapsing the group also closes its children;
failed requests remain accessible and permission requests stay visible.

Responses use the same framed panel as Read, without line numbers. Search
results and Markdown pages retain their formatting; HTML and plain text keep
their original content. Expanded requests show the full query or URL and
request options, including details shortened in the compact row.

# Skills

Skill calls appear as a compact `→ Skill "name"` row. Press `O` or `Enter` to
show the description, base directory, sampled files, and full instructions in
the same framed panel as Read and Web, without line numbers. Markdown and code
highlighting survive line wrapping. Each skill remains independently expandable;
loading animates only its header, and failed calls expose their error on expansion.

`/skills` and the command palette add native skill references to the
current input draft and insert visible `@skill-id` mentions. Select `/skills`
with Enter, Tab, or the send key to open the skill selector. You can keep editing
the prompt or add more skills; selection alone does not send a message. Sending
the draft loads the skills on the server. Each selected skill then appears below
the user message as an independent expandable row. `Attached` means the server
returned the instructions; a queued message still shows its own delivery status.
Use `O` or `Enter` to inspect that message's saved instructions. If the server
did not include the text, the row shows `Unconfirmed` and explains that the
instructions are unavailable. These attachments do not create tool calls.

# Status

Select `/status` from completion with Enter, Tab, or the send key, or submit
`/status`, to open the existing status popup. Closing it returns to the chat
input with the remaining draft and attachments when that chat is still active.
Use `/stats` for session usage statistics.

# Side questions

Type `/btw <question>` in the input and press Enter to ask using the current
session context and model. The input closes while a `/btw` spinner appears in the
session tab bar. The answer opens in a centered dialog and is not added to the
conversation. Press `c` to copy the answer, use the arrow keys or Page Up/Down to
scroll, and press `Esc` to dismiss it. Bare `/btw` or the command palette opens a
short question prompt.

# Inline code completion

Enable manually requested ghost text in ordinary editable file buffers:

```lua
require("opencode").setup({
  completion = {
    enabled = true,
    model = { providerID = "your-provider", modelID = "your-fast-model" },
    -- variant = "completion", -- optional variant configured in OpenCode
    keymaps = { trigger = "<C-l>", accept = "<Tab>" },
    timeout_ms = 15000,
    max_lines = 12,
  },
})
```

In Insert mode, **Ctrl+L** requests a suggestion and displays a spinner at the
cursor. Press it again to cancel the pending request or ask for an alternative
to the visible suggestion. **Tab** inserts the entire suggestion as a separate
undo step. While waiting, or without a suggestion, Tab keeps its usual mapping.
Typing, moving the cursor, leaving Insert mode, or switching buffers dismisses
the suggestion. A late response cannot insert or display stale code.

Completion inserts between the cursor and the existing text to its right; it
never replaces that suffix. With a suffix, suggestions stay on one line. At the
end of a line, they can contain a short block. Preview does not modify the file;
long virtual lines are clipped to the window width. Inline virtual text requires
Neovim 0.10 or newer. Customize `OpenCodeCompletion` and
`OpenCodeCompletionSpinner` highlight groups with `nvim_set_hl`.

The model must be configured explicitly; completion does not inherit the chat
model. OpenCode 2.0.11–2.0.12 uses `/api/experimental/generate` for this buffered,
sessionless request: no tools run and nothing is added to chat history. The
spinner remains until the complete response arrives. Canceling closes this
request's local connection; provider-side generation cancellation depends on
OpenCode and the provider. On a cold server, completion allows up to two seconds
for the separate base model catalog to initialize, within the overall timeout.
Only explicit model/variant-unavailable rejections are retried; provider failures
and uncertain requests are never automatically repeated.

For a server launched by the plugin, configure provider-specific model options
directly in Lua instead of selecting an existing variant:

```lua
completion = {
  enabled = true,
  model = { providerID = "openai", modelID = "your-fast-model" },
  options = {
    -- For a native OpenAI Responses model supporting reasoningEffort="none":
    settings = { reasoningEffort = "none" },
    body = { max_output_tokens = 256 },
    -- headers = { ... },
  },
}
```

`settings`, `body`, and `headers` follow OpenCode's
[model overlay format](https://opencode.ai/v2/docs/models#options). They are
provider-specific: `none` is not supported by every reasoning model, and raw
token-budget fields differ between provider APIs. Generic `settings.maxTokens`
or `settings.temperature` are not translated into generation parameters by
this endpoint. Choose a model without reasoning, or explicitly disable it using
its supported options.

The plugin installs an internal completion variant in the managed server's
`OPENCODE_CONFIG_CONTENT` environment, preserving other JSON/JSONC configuration
and model variants. It does not edit config files or change the chat default.
Options take effect when that server starts; after changing them, use
`:OpenCodeRestart`. The plugin never silently restarts an ongoing chat.
`options` and `variant` are mutually exclusive. With an external server
(`server.port`), configure the variant in that server's base/global configuration
and set `completion.variant`; Lua `options` require a managed server. In
OpenCode 2.0.11–2.0.12, sessionless generation uses the server's base
configuration, so project-only model variants are insufficient.

Context comes from the unsaved current buffer: cursor prefix/suffix, surrounding
lines, file header, language, and indentation settings. It also includes up to
two related, loaded file buffers from the same project, prioritizing referenced
paths/names and then same-directory files of the same language. This feature
does not scan file contents on disk or issue LSP requests. Limits are configurable:

```lua
completion = {
  -- enabled/model/keymaps/options as above
  context = {
    max_bytes = 24576, -- entire serialized prompt, including instructions
    before_lines = 150,
    after_lines = 50,
    header_lines = 60,
    max_related_buffers = 2, -- use 0 for current-buffer context only
    related_lines = 60,
  },
}
```

Set either completion keymap to `false` to integrate with your own mappings or
completion framework. The public API is `require("opencode").complete()`,
`accept_completion()` (returns whether acceptance was queued),
`dismiss_completion()`, and `completion_visible()`. Acceptance is safe from an
expression mapping; the actual insertion runs outside Neovim's textlock.
The automatic Tab mapping exists only while ghost text is ready and restores
previous buffer-local mappings when it disappears.

# Explain a Visual selection

Enable explanations separately from inline completion:

```lua
require("opencode").setup({
  explanation = {
    enabled = true, -- disabled by default
    model = { providerID = "ollama-cloud", modelID = "deepseek-v4.1-flash" },
    -- variant = "brief", -- use an existing OpenCode variant instead of options
    options = { body = { reasoning_effort = "none" } },
    language = "en",
    -- prompt = "Explain these selected lines in {language} by logical block.",
    keymaps = { trigger = "K" }, -- Visual mode only; false disables the mapping
    timeout_ms = 60000,
    context = {
      max_bytes = 24576,
      before_lines = 150,
      after_lines = 50,
      header_lines = 60,
      max_related_buffers = 2,
      related_lines = 60,
    },
  },
})
```

Select code in Visual mode and press `K` (`<S-k>`). A scrollable popup opens
immediately with a spinner, then shows the finished answer. The default
prompt asks for concise Markdown explanations of consecutive logical blocks
with exact source ranges, such as `L24–27 — …`, covering every nonempty part
of the selection without repeating the code. It asks the model to wrap the
final answer in `<answer>` markers. When those markers are present, the popup
shows only the final answer; otherwise it shows the response as received.
Press `c` to copy the answer; `q` or `Esc` closes the popup and cancels a pending
request. Normal-mode `K` remains available for LSP hover. Call
`require("opencode").explain_selection()` from your own Visual mapping if needed.

Set `explanation.prompt` to replace the default instruction. The optional
`{language}` placeholder uses `explanation.language`. The plugin appends the
selection and context as JSON after either instruction; the custom prompt is
included in the `max_bytes` budget. A custom prompt can request any response
format; its response is shown unchanged. The plugin does not check line ranges.

The request uses the unsaved source buffer, surrounding lines, file header, and
related loaded buffers. The full selection has priority within `max_bytes`; if
it alone exceeds the budget, the popup shows an error instead of truncating it.
The source buffer is never edited. Generation uses the sessionless
`/api/experimental/generate` endpoint without tools or chat history, and late
answers are ignored after closing the popup or changing the source buffer.

Explanation has its own model, variant, options, and context settings. For a
server launched by the plugin, `options` creates a private variant independent
of completion; apply changed options with `:OpenCodeRestart`. Set either
`variant` or `options`, not both. With an external server, configure a named
variant on that server and set `explanation.variant`.

# Popup borders

Set `popup.border` in `require("opencode").setup()` to style the outer edge of
dialogs such as **Switch Session**, help, and `/btw`. The default is `"solid"`.
The supported values are `"none"`, `"single"`, `"double"`, `"rounded"`,
`"solid"`, or a custom Nui border character table. Inner list, search, and
tab windows do not get their own border. With `"none"`, text normally placed
on the border (such as a popup title) is hidden.

```lua
require("opencode").setup({
  popup = { border = "rounded" },
  chat = {
    layout = "float",
    float = { border = "solid" }, -- applies only to the floating chat
  },
  palette = { border = "none" }, -- command palette border is independent
})
```

# Tokens per second

Assistant footers show average generation speed, for example `42.7 tok/s`.
Like OpenCode v2, this sums output and reasoning tokens across the current turn
and divides by the total model request time (`time.streamed - time.created`).
Tool execution time is excluded. The value appears when the server supplies
stream timing and token usage, including when loading session history.

TPS is enabled by default. Set `chat.tps = false` to hide it:

```lua
require("opencode").setup({ chat = { tps = false } })
```

# Code highlighting

Fenced code blocks in user messages and assistant replies use the installed
Tree-sitter parser and highlight queries for their language. Open fences and
incomplete code are highlighted while the answer streams. The same highlighting
is used when loading history, with source positions preserved through wrapping
and shortened user messages. Sent user messages and assistant replies render
Markdown and hide fence delimiters; the input keeps the original editable source
visible.

Chat messages share OpenTUI's top-level Markdown renderer, using Neovim's
window padding and the existing user-message box: block-specific spacing, styled
headings/emphasis, concealed inline markers, literal code blocks, nested lists,
quote borders, horizontal
rules and full-width grid tables. This uses the `markdown` and `markdown_inline`
Tree-sitter parsers (bundled with current Neovim); if unavailable, source text
remains readable. Streaming and history use the same renderer.

`OpenCodeMarkdownHeading`, `OpenCodeMarkdownHeading1`, `OpenCodeMarkdownStrong`,
`OpenCodeMarkdownEmphasis`, `OpenCodeMarkdownCode`, `OpenCodeMarkdownLink`,
`OpenCodeMarkdownLinkText`, `OpenCodeMarkdownQuote`, `OpenCodeMarkdownBorder`,
`OpenCodeMarkdownList` and `OpenCodeMarkdownStrike` control Markdown styles.
Their defaults use the current Neovim colorscheme; exact RGB colors and code
syntax colors depend on that colorscheme and the installed language queries.

```lua
require("opencode").setup({
  syntax = {
    enabled = true,
    user_markdown = true,
    assistant_markdown = true, -- includes streaming replies
    input_markdown = true,     -- includes open fences while editing the draft
    max_lines = 500,           -- per code block
    max_bytes = 200 * 1024,
    languages = {},            -- optional language aliases
  },
})
```

For example, a `rust` fence needs a Rust parser and `highlights.scm` queries on
Neovim's runtimepath. Missing parsers/queries, unknown languages and blocks over
the limits fall back to plain text; parsers are not installed automatically.
Explicitly labelled fences also highlight snippets shorter than `syntax.min_bytes`.
Set `syntax.enabled = false` to disable fenced-code highlighting. Standalone
backtick/tilde fences are supported in all surfaces; sent messages also
parse nested Markdown containers.

The current-line and visual-selection helpers (including the suggested
`<leader>oe` and `<leader>oa` mappings below) add code in a fenced Markdown block.
The language comes from the source buffer's `filetype`, with filename detection
as a fallback; unknown languages leave the fence unlabelled. The `@file#lines`
reference stays above the block. Selections containing backtick fences use a
longer outer fence so the selected text remains intact.

Fenced code also highlights in the input widget while typing, pasting, undoing
edits and restoring drafts or history, including blocks without a closing fence.
It uses the same language parsers and per-block limits as chat. Set
`syntax.input_markdown = false` to disable highlighting only in the input.

# Testing

Install pinned Neovim and server-plugin test dependencies once (Node.js and npm required):

```sh
./scripts/bootstrap-test-deps.sh
```

Run the Plenary/Busted test suite:

The full suite also runs the bundled TypeScript tool tests with Bun. Install Bun
or set `OPENCODE_NVIM_BUN` to its executable path. Bootstrap installs the exact
OpenCode 2.0.11 API dependencies and TypeScript compiler used by the tool suite.

```sh
./tests/run.sh              # all specs
./tests/run.sh unit         # unit specs
./tests/run.sh checks       # architecture/state guardrails
./tests/run.sh integration  # integration specs
./tests/run.sh smoke        # smoke specs
./tests/run.sh tools        # Bun tool tests, including the Neovim edit-review path
```

The runner uses temporary Neovim configuration, data, state, cache and log paths.
Each Lua spec process has its own profile, removed when the run finishes. Tests
use the real pinned Nui and Plenary dependencies.

The live server/skill smoke test is reported as pending unless the runtime
harness supplies its isolated server and explicit model. A normal suite run
does not exercise a live model.

Verify completion against an installed OpenCode binary and a loopback mock
model (temporary configuration, no account credentials or paid requests):

```sh
python3 tests/runtime/completion_backend.py
# Or select a minimum-version binary explicitly:
python3 tests/runtime/completion_backend.py --cli /path/to/opencode-2.0.11
```

This checks the real stateless endpoint, model options, cold-catalog startup,
history isolation, and whether cancellation reaches the mock provider.

You can also run a single spec file:

```sh
./tests/run.sh tests/unit/input_history_spec.lua
```

# Installation

The backend requires **OpenCode 2.0.11 or newer**.

Run `./scripts/install-tools.sh` to install the bundled v2 server plugin into
`$XDG_CONFIG_HOME/nvim/opencode` (or `~/.config/nvim/opencode`). Pass a directory
argument when `server.config_dir` uses a different location. Node.js and npm are
required to install the pinned runtime dependencies. The installer preserves
user commands and JSONC comments, adds its v2 plugin entry, and keeps backups
under `opencode-nvim-backups` on reinstall. It checks for unsupported config
entries and tool files before changing the profile; resolve any reported path
and rerun the installer.

The bundled tools use two distinct decisions: native OpenCode permission rules
authorize the operation, then Neovim reviews each proposed file. `allow` on a tool
does not accept its diff. The tools wait for the Neovim connection and never
accept edits merely because no UI is connected.

Review of an external server applies accepted files on that server after all
files have a decision. Local native diff and manual resolution require
`server.shared_filesystem = true`: set this only when Neovim sees the same files
at the server's paths. A server started by this plugin shares the local filesystem
automatically. Inline proposals (`=`), acceptance and rejection also work without
shared files. Disconnected or cancelled reviews cannot apply or flush files.

Bundled plugin **2.0.11-4** provides file review protocol 2. Update it
together with the Lua plugin. `/skills` and the skill palette stage native
attachments, which are sent with the prompt when you submit the input.

`neovim_edit` follows the v2 edit input: `path`, non-empty `oldString`,
`newString`, and optional `replaceAll`. It only changes existing files.
Use `neovim_patch` with `patchText` to add,
update, move, or delete files. Both retain preview, per-file accept/reject, manual
diff editing, and the optional `allowIndentChange` guard override. User review
comments accompany the tool's model-visible result and persist in chat history.

Permissions remain scoped to `neovim_edit` and `neovim_patch`; they are not
broadened to cover all built-in `edit` operations. Unknown historical tool calls
render through the generic tool view without review actions. Reinstall the bundled
server plugin and reconnect when updating: protocol 2 prevents an older server
from silently dropping review comments.

Model preferences use format 2 in `opencode_local.json`. A versionless file is
left untouched and is not loaded; move it aside and reselect preferences in the
UI, or manually convert its model IDs and add `"version": 2`. Unavailable
favorites in a version 2 file are retained. Existing sessions keep their own
model, agent and variant until you explicitly change them.

Prompts sent while a response is running are queued by default. Pending inputs
stay at the bottom of the chat, below the current response and its status footer,
until delivery is confirmed. They then move into the conversation history.
Press `S` on a queued message to steer the active agent with that same input.
Its label changes to **Steering pending** after the server confirms the change;
it is applied between agent steps, without aborting a running tool.
On a pending message, press `C` to cancel it or `E` to remove it from the inbox
and edit its text and attachments in the input. Send the edited draft with `<C-g>`.
These keys act on the pending widget under the cursor (including its status line);
outside it they keep their normal Neovim behavior.
The pending label disappears once delivery is confirmed. **Cancel Pending Input**
is also available in the palette. Configure or disable these chat keys with:

```lua
require("opencode").setup({
  chat = { keymaps = { cancel_pending = "C", edit_pending = "E", steer_pending = "S" } }, -- false or "" disables a key
})
```

Chat `<C-c>` interrupts the current execution and leaves inbox inputs pending.
Scripts can explicitly request steering with `send(text, { delivery = "steer" })`.
After a connection loss, an unknown delivery outcome stays visible while it is
reconciled with the server; it is never automatically resent.

Current transport supports HTTP and Basic authentication, without direct TLS.
For an owned server without a configured password, the plugin generates an
ephemeral password and uses it for both HTTP and SSE. External servers require
their configured credentials. File URI attachments refer to files accessible to the server; clipboard
images use inline data URIs. OpenCode 2.0.11 does not run LSP diagnostics and
does not expose MCP tool definitions through its public catalog. MCP status,
connection and linked integration authentication remain available.

Paste the prompt below into your AI coding agent while it is working in your Neovim config directory.
It will inspect your setup, install opencode.nvim with your existing plugin manager, and configure safe defaults.

````text
Install and configure opencode.nvim in this Neovim config.

Follow these steps:
1. Inspect the current Neovim config first. Identify the plugin manager, config structure, existing keymap style, colors/highlight setup, and any existing OpenCode or AI-assistant config.
2. Ask targeted questions only when a choice is not obvious. Ask, for example, which plugin manager to use if it is unclear, which keymap should toggle/open opencode, whether session tabs should use a fixed max count or dynamic auto-fit, and whether the chat layout should be vertical, horizontal, or float.
3. Add `wwnbb/opencode.nvim` through the existing plugin manager. Include dependencies: MunifTanjim/nui.nvim and nvim-lua/plenary.nvim. If the config uses lazy.nvim, ask whether I want you to install/sync the plugin now by running `nvim --headless "+Lazy! sync" +qa`; run it only if I confirm.
4. Configure the plugin manager build/install hook to run `scripts/install-tools.sh` so the bundled opencode.nvim server plugin is updated with the Lua plugin. If the plugin manager has no build hook, run the script manually from the plugin root. Verify `opencode --version` reports 2.0.11 or newer, then connect and inspect Server Status in the command palette.
5. Configure `require("opencode").setup()` using only supported options:
   - `server.command`, `server.auto_start`, `server.config_dir`, `server.env`
   - `session.default_agent`, `session.default_model.providerID`, `session.default_model.modelID`, `session.parallel.enabled`
   - `chat.layout` (`vertical`, `horizontal`, or `float`), `chat.position`, `chat.width`, `chat.height`, `chat.float.width`, `chat.float.height`, `chat.float.border`, `chat.close_on_focus_lost`
   - `popup.border` (`none`, `single`, `double`, `rounded`, `solid`, or a Nui border character table)
   - `chat.session_tabs.enabled`, `chat.session_tabs.auto_fit`, `chat.session_tabs.max_tabs`, `chat.session_tabs.separator`, `chat.session_tabs.icons`, `chat.session_tabs.colors`
   - top-level `keymaps.toggle`, `keymaps.command_palette`, `keymaps.toggle_logs`, `keymaps.close_session`, `keymaps.abort`, `keymaps.active_sessions`
   - `input.keymaps.send`, `input.keymaps.cancel`, `input.keymaps.variant_cycle`, `input.keymaps.agent_cycle`, `input.keymaps.model_cycle`
   - `lualine.enabled`, `notifications.enabled`
   - Keep `danger_mode = false`; do not enable it unless I explicitly request the security tradeoff.
6. Configure colors/highlights to match the existing colorscheme. Session tabs inherit Neovim's `TabLine`, `TabLineSel`, and `TabLineFill` groups by default; use `chat.session_tabs.colors` only when custom tab colors are needed, and `vim.api.nvim_set_hl` for existing `OpenCode*` highlight groups when needed.
7. Configure keybindings consistently with the rest of this config, avoiding collisions.
8. Suggest optional keymaps for adding the current line or visual selection to the opencode.nvim chat context. Adapt the mappings and keymap helper to the user's existing config style, for example:

```lua
local oc = require("opencode")

keyset("n", "<leader>oe", oc.add_current_line_and_open_input, {})
keyset("x", "<leader>oe", oc.add_visual_selection_and_open_input, {})
keyset("n", "<leader>oa", oc.add_current_line, {})
keyset("x", "<leader>oa", oc.add_visual_selection, {})
```

9. If this config already has an `nvim-tree` toggle/explore keymap that should take over the side panel, ask whether opening `nvim-tree` should hide opencode.nvim first. If the user wants that behavior, suggest one of these optional helpers. Use the keymap wrapper when only that toggle should hide opencode.nvim; keep the user's existing path/argument logic and replace `"<arg>"` with whatever that keymap currently passes.

```lua
local function hide_opencode_chat()
  local ok, opencode = pcall(require, "opencode")
  if ok and type(opencode.close) == "function" then
    opencode.close()
  end
end

local function explore()
  -- path = vim.fn.expand("%")
  hide_opencode_chat()
  api.tree.toggle({ find_file = true, focus = true, path = "<arg>" })
end
```

Alternatively, use a `FileType` autocmd when opencode.nvim should hide whenever any `NvimTree` window opens:

```lua
local function hide_opencode_chat()
  local ok, opencode = pcall(require, "opencode")
  if ok and type(opencode.close) == "function" then
    opencode.close()
  end
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("NvimTreeHideOpenCode", { clear = true }),
  pattern = "NvimTree",
  callback = function()
    vim.schedule(hide_opencode_chat)
  end,
})
```

10. Verify by loading/requiring the edited config if possible, such as with a headless Neovim require check or the config's existing lightweight validation command.

Compact setup example to adapt after registering the plugin with the existing plugin manager:

```lua
require("opencode").setup({
  server = {
    command = "opencode",
    auto_start = true,
  },
  session = {
    default_agent = "build",
    default_model = {
      providerID = "github-copilot",
      modelID = "gpt-5-mini",
    },
    parallel = {
      enabled = true,
    },
  },
  chat = {
    layout = "vertical",
    position = "right",
    width = 80,
    close_on_focus_lost = true,
    session_tabs = {
      enabled = true,
      auto_fit = false,
      max_tabs = 3,
      separator = " │ ",
      icons = {
        running = "●",
        waiting = "◈",
        idle = "○",
        error = "✕",
      },
    },
  },
  keymaps = {
    toggle = "<leader>oo",
    command_palette = "<leader>op",
    toggle_logs = "<leader>ol",
    close_session = "<leader>oq",
    abort = "<leader>ox",
    active_sessions = "<leader>oS",
  },
  input = {
    keymaps = {
      send = "<C-g>",
      cancel = "<Esc>",
      variant_cycle = "<C-t>",
      agent_cycle = "<C-a>",
      model_cycle = "<C-e>",
    },
  },
  lualine = { enabled = true },
  notifications = { enabled = true },
  danger_mode = false,
})
```
For the five global OpenCode mappings (`toggle`, `command_palette`, `toggle_logs`,
`close_session`, and `active_sessions`), use `false` or `""` to disable a key.
Changing a key removes the previous plugin mapping.
````
