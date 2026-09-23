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
and shortened user messages. Fence delimiters remain visible.

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
The legacy `markdown.enable_code_highlight = false` disables fenced-code
highlighting in messages and the input. Standalone backtick/tilde fences are supported;
nested Markdown containers such as block quotes are not parsed by this renderer.

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

You can also run a single spec file:

```sh
./tests/run.sh tests/unit/input_history_spec.lua
```

# Installation

The backend targets **OpenCode 2.0.11**; this checkout does not provide a v1
backend. See [migration progress](plans/opencode-v2/PROGRESS.md) for the remaining
validation work. Keep your previous plugin checkout and configuration when
upgrading; reverting the Neovim plugin does not reverse server database migration.

Run `./scripts/install-tools.sh` to install the bundled v2 server plugin into
`$XDG_CONFIG_HOME/nvim/opencode` (or `~/.config/nvim/opencode`). Pass a directory
argument when `server.config_dir` uses a different location. Node.js and npm are
required to install the pinned runtime dependencies. The installer preserves
user commands and JSONC comments, adds its plugin entry, migrates legacy
permission rules, and keeps backups under `opencode-nvim-backups`. Only unchanged,
identified v1 tool files are retired; modified files are retained.

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

Bundled plugin **2.0.11-3** provides file review protocol 2 and persistent
`todoread`/`todowrite` tools. Update it together with the Lua plugin. `/skill`
and the skill palette send native attachments; the unchanged legacy
`load_skills` command is backed up and retired by the installer.

`neovim_edit` follows the v2 edit input: `path`, non-empty `oldString`,
`newString`, and optional `replaceAll`. It only changes existing files.
Use `neovim_patch` (renamed from `neovim_apply_patch`) with `patchText` to add,
update, move, or delete files. Both retain preview, per-file accept/reject, manual
diff editing, and the optional `allowIndentChange` guard override. User review
comments accompany the tool's model-visible result and persist in chat history.

The installer renames exact `neovim_apply_patch` permission actions to
`neovim_patch`, including agent rules, preserving their resources and ordering.
Permissions remain scoped to `neovim_edit` and `neovim_patch`; they are not
broadened to cover all built-in `edit` operations. Old tool calls still render
in history. Reinstall the bundled server plugin and reconnect when updating:
protocol 2 prevents an older server from silently dropping review comments.

Model preferences use format 2 in `opencode_local.json`; the first format
conversion preserves the original as `opencode_local.json.v1.bak`. Unavailable
favorites are retained. Existing sessions keep their own model, agent and
variant until you explicitly change them.

Prompts sent while a response is running are queued and labelled in the chat.
Use **Cancel Pending Input** in the palette to remove one queued prompt. Chat
`<C-c>` interrupts the current execution and leaves queued inputs pending.
Scripts can explicitly request steering with `send(text, { delivery = "steer" })`;
it is applied at the server's next delivery boundary, without aborting a running tool.
After a connection loss, an unknown delivery outcome stays visible while it is
reconciled with the server; it is never automatically resent.

Current transport supports HTTP and Basic authentication, without direct TLS.
For an owned server without a configured password, the plugin generates an
ephemeral password and uses it for both HTTP and SSE. External servers require
their configured credentials. File URI attachments refer to files accessible to the server; clipboard
images use inline data URIs. OpenCode 2.0.11 does not run LSP diagnostics and
does not expose MCP tool definitions through its public catalog. MCP status,
connection and linked integration authentication remain available.

Runtime validation uses isolated profiles: MiMo V2.5 Free from OpenCode Zen
for the main matrix and DeepSeek V4 Flash from OpenCode Go for successful
parallel background agents, reconnect and fresh-client history. Zen Free
rejected child-agent requests with a provider restriction. See
[the validation report](plans/opencode-v2/FINAL-VALIDATION.md) for evidence and limits.
Importing old v1 conversation history is outside this migration’s scope.


Paste the prompt below into your AI coding agent while it is working in your Neovim config directory.
It will inspect your setup, install opencode.nvim with your existing plugin manager, and configure safe defaults.

````text
Install and configure opencode.nvim in this Neovim config.

Follow these steps:
1. Inspect the current Neovim config first. Identify the plugin manager, config structure, existing keymap style, colors/highlight setup, and any existing OpenCode or AI-assistant config.
2. Ask targeted questions only when a choice is not obvious. Ask, for example, which plugin manager to use if it is unclear, which keymap should toggle/open opencode, whether session tabs should use a fixed max count or dynamic auto-fit, and whether the chat layout should be vertical, horizontal, or float.
3. Add `wwnbb/opencode.nvim` through the existing plugin manager. Include dependencies: MunifTanjim/nui.nvim and nvim-lua/plenary.nvim. If the config uses lazy.nvim, ask whether I want you to install/sync the plugin now by running `nvim --headless "+Lazy! sync" +qa`; run it only if I confirm.
4. Configure the plugin manager build/install hook to run `scripts/install-tools.sh` so the bundled opencode.nvim server plugin is updated with the Lua plugin. If the plugin manager has no build hook, run the script manually from the plugin root. Verify `opencode --version` reports 2.0.11, then connect and inspect Server Status in the command palette.
5. Configure `require("opencode").setup()` using only supported options:
   - `server.command`, `server.auto_start`, `server.config_dir`, `server.env`
   - `session.default_agent`, `session.default_model.providerID`, `session.default_model.modelID`, `session.parallel.enabled`, `session.parallel.use_prompt_async`
   - `chat.layout` (`vertical`, `horizontal`, or `float`), `chat.position`, `chat.width`, `chat.height`, `chat.float.width`, `chat.float.height`, `chat.float.border`, `chat.close_on_focus_lost`
   - `chat.session_tabs.enabled`, `chat.session_tabs.auto_fit`, `chat.session_tabs.max_tabs`, `chat.session_tabs.separator`, `chat.session_tabs.icons`, `chat.session_tabs.colors`
   - top-level `keymaps.toggle`, `keymaps.command_palette`, `keymaps.abort`, `keymaps.active_sessions`
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
      use_prompt_async = true,
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
````
