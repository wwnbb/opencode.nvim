#!/usr/bin/env bash
# Copy the prepared v2 server plugin into Neovim's private OpenCode profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec nvim --headless --noplugin -u NONE -i NONE -n -l "$SCRIPT_DIR/install-tools.lua" "${1:-${XDG_CONFIG_HOME:-$HOME/.config}/nvim/opencode}"
