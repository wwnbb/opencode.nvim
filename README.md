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

# Testing

Install pinned Neovim test dependencies once:

```sh
./scripts/bootstrap-test-deps.sh
```

Run the Plenary/Busted test suite:

```sh
./tests/run.sh              # all specs
./tests/run.sh unit         # unit specs
./tests/run.sh checks       # architecture/state guardrails
./tests/run.sh integration  # integration specs
./tests/run.sh smoke        # smoke specs
```

You can also run a single spec file:

```sh
./tests/run.sh tests/unit/input_history_spec.lua
```

# Installation

Paste the prompt below into your AI coding agent while it is working in your Neovim config directory.
It will inspect your setup, install opencode.nvim with your existing plugin manager, and configure safe defaults.

````text
Install and configure opencode.nvim in this Neovim config.

Follow these steps:
1. Inspect the current Neovim config first. Identify the plugin manager, config structure, existing keymap style, colors/highlight setup, and any existing OpenCode or AI-assistant config.
2. Ask targeted questions only when a choice is not obvious. Ask, for example, which plugin manager to use if it is unclear, which keymap should toggle/open opencode, whether session tabs should use a fixed max count or dynamic auto-fit, and whether the chat layout should be vertical, horizontal, or float.
3. Add `wwnbb/opencode.nvim` through the existing plugin manager. Include dependencies: MunifTanjim/nui.nvim and nvim-lua/plenary.nvim. If the config uses lazy.nvim, ask whether I want you to install/sync the plugin now by running `nvim --headless "+Lazy! sync" +qa`; run it only if I confirm.
4. Configure the plugin manager build/install hook to run `scripts/install-tools.sh` at least once so the bundled opencode.nvim config/tools are installed. If the plugin manager has no build hook, run `scripts/install-tools.sh` manually from the plugin root. After install, run `opencode debug config` to verify the OpenCode config is correct.
5. Configure `require("opencode").setup()` using only supported options:
   - `server.command`, `server.auto_start`, `server.reuse_running`, `server.config_dir`, `server.env`
   - `session.default_agent`, `session.default_model.providerID`, `session.default_model.modelID`, `session.parallel.enabled`, `session.parallel.use_prompt_async`
   - `chat.layout` (`vertical`, `horizontal`, or `float`), `chat.position`, `chat.width`, `chat.height`, `chat.float.width`, `chat.float.height`, `chat.float.border`, `chat.close_on_focus_lost`
   - `chat.session_tabs.enabled`, `chat.session_tabs.auto_fit`, `chat.session_tabs.max_tabs`, `chat.session_tabs.separator`, `chat.session_tabs.icons`, `chat.session_tabs.colors`
   - top-level `keymaps.toggle`, `keymaps.command_palette`, `keymaps.abort`, `keymaps.active_sessions`
   - `input.keymaps.send`, `input.keymaps.cancel`, `input.keymaps.paste`, `input.keymaps.variant_cycle`, `input.keymaps.agent_cycle`, `input.keymaps.model_cycle`
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
    reuse_running = true,
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
      paste = "<C-v>",
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
