#!/usr/bin/env python3
"""Exercise the real installer in a disposable profile, including reinstall."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
profile = Path(tempfile.mkdtemp(prefix="opencode-nvim-install-test-"))
config = profile / "opencode"
config.mkdir()
original = '''{
  // Keep this user's comment.
  "plugins": ["example-user-plugin"],
  "permission": { "rg": "deny", "neovim_edit": { "*.lua": "ask" }, "neovim_apply_patch": "deny" },
  "permissions": [{ "action": "read", "resource": "*.env", "effect": "deny" }],
  "agents": { "build": { "permissions": [{ "action": "neovim_apply_patch", "resource": "*.md", "effect": "ask" }] } },
  "commands": { "mine": { "description": "User command", "template": "Keep me" } },
  "mcp": {},
}
'''
(config / "opencode.jsonc").write_text(original)
(config / "commands").mkdir()
(config / "commands/load_skills.md").write_text("User's edited command\n")
(config / "tool").mkdir()
(config / "tool/neovim_edit.ts").write_text("User's custom tool\n")
legacy = repo / "opencode_nvim/plugins/opencode-nvim/tools/rg.txt"
assert hashlib.sha256(legacy.read_bytes()).hexdigest() == json.loads((repo / "scripts/legacy-tools-sha256.json").read_text())["tool/rg.txt"]
(config / "tool/rg.txt").write_bytes(legacy.read_bytes())
for run in range(2):
    subprocess.run([str(repo / "scripts/install-tools.sh"), str(config)], check=True)
    parse = '''const fs=require('fs');const parser=require(process.argv[1]);console.log(JSON.stringify(parser.parse(fs.readFileSync(process.argv[2],'utf8'))));'''
    value = json.loads(subprocess.check_output(["node", "-e", parse,
        str(config / "plugins/opencode-nvim/node_modules/jsonc-parser"), str(config / "opencode.jsonc")]))
    assert value["plugins"] == ["example-user-plugin", str(config / "plugins/opencode-nvim")]
    assert value["permissions"] == [
        {"action": "rg", "resource": "*", "effect": "deny"},
        {"action": "neovim_edit", "resource": "*.lua", "effect": "ask"},
        {"action": "neovim_patch", "resource": "*", "effect": "deny"},
        {"action": "read", "resource": "*.env", "effect": "deny"},
    ]
    assert value["agents"]["build"]["permissions"] == [{"action": "neovim_patch", "resource": "*.md", "effect": "ask"}]
    assert (config / "plugins/opencode-nvim/tools/neovim_patch.ts").exists()
    assert not (config / "plugins/opencode-nvim/tools/neovim_apply_patch.ts").exists()
    assert "Keep this user's comment" in (config / "opencode.jsonc").read_text()
    assert value["commands"]["mine"]["template"] == "Keep me"
    assert (config / "commands/load_skills.md").read_text() == "User's edited command\n"
    assert (config / "tool/neovim_edit.ts").read_text() == "User's custom tool\n"
    assert not (config / "tool/rg.txt").exists()
    assert any(p.read_text() == original for p in (config / "opencode-nvim-backups").glob("*/opencode.jsonc"))
print("Installer preservation and reinstall passed:", profile)
