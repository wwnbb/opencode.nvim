# Markdown parity fixtures

`markdown-oracle.ts` runs the actual OpenTUI 0.4.1 MarkdownRenderable used by the
local reference. It records visible rows and per-cell style runs for the cases
in `../fixtures/markdown/cases.json`, at 77 and 25 columns. Cases with `updates`
reuse the same renderable across streaming deltas.

Generate with an isolated test dependency (Bun required):

```sh
bun add --cwd /tmp/opencode-tui-parity --ignore-scripts @opentui/core@0.4.1
OPENCODE_TUI_ORACLE_ROOT=/tmp/opencode-tui-parity/node_modules bun tests/reference/markdown-oracle.ts
./tests/run.sh tests/unit/markdown_reference_spec.lua
```

The generated `tui.json` is checked in, so the normal Lua tests need neither Bun
nor OpenTUI. Distinct synthetic colors identify semantic styles in comparisons;
production colors continue to come from Neovim. Language-specific code colors
are intentionally outside these comparisons and use the existing Neovim
Tree-sitter highlighting tests.

The reference runs with concealment, streaming, top-level blocks and grid tables
as configured by OpenCode's TextPart. Rendering waits for asynchronous syntax
highlighting before reading the native cell buffer. The Markdown query files
under `lua/opencode/ui/markdown/queries` come from OpenTUI and retain its license.
