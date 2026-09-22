#!/usr/bin/env bash
# Install the pinned v2 server plugin into Neovim's private OpenCode profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/install-tools.mjs" "${1:-${XDG_CONFIG_HOME:-$HOME/.config}/nvim/opencode}"
