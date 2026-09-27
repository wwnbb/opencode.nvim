#!/usr/bin/env python3
"""Exercise strict v2 installation, reinstall, and non-mutating config refusal."""
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
  "permissions": [
    { "action": "neovim_edit", "resource": "*.lua", "effect": "ask" },
    { "action": "neovim_patch", "resource": "*.md", "effect": "ask" }
  ],
  "commands": { "mine": { "description": "User command", "template": "Keep me" } },
  "mcp": {},
}
'''
config_file = config / "opencode.jsonc"
config_file.write_text(original)
(config / "commands").mkdir()
(config / "commands/custom.md").write_text("User's command\n")
(config / "tool").mkdir()
(config / "tool/custom.ts").write_text("User's custom tool\n")


def install(directory, success=True, reason=None):
    result = subprocess.run([str(repo / "scripts/install-tools.sh"), str(directory)], capture_output=True, text=True)
    if success:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0, result.stdout + result.stderr
        assert reason in result.stderr, result.stderr
    return result


def parse_config():
    parser = config / "plugins/opencode-nvim/node_modules/jsonc-parser"
    code = "const fs=require('fs');const p=require(process.argv[1]);console.log(JSON.stringify(p.parse(fs.readFileSync(process.argv[2],'utf8'))))"
    return json.loads(subprocess.check_output(["node", "-e", code, str(parser), str(config_file)]))


def snapshot(directory):
    result = {}
    for path in directory.rglob("*"):
        relative = str(path.relative_to(directory))
        if path.is_symlink():
            result[relative] = "link:" + os.readlink(path)
        elif path.is_dir():
            result[relative] = "dir"
        else:
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


for run in range(2):
    install(config)
    value = parse_config()
    assert value["plugins"] == ["example-user-plugin", str(config / "plugins/opencode-nvim")]
    assert value["permissions"] == [
        {"action": "neovim_edit", "resource": "*.lua", "effect": "ask"},
        {"action": "neovim_patch", "resource": "*.md", "effect": "ask"},
    ]
    assert (config / "plugins/opencode-nvim/tools/neovim_patch.ts").exists()
    assert "Keep this user's comment" in config_file.read_text()
    assert value["commands"]["mine"]["template"] == "Keep me"
    assert (config / "commands/custom.md").read_text() == "User's command\n"
    assert (config / "tool/custom.ts").read_text() == "User's custom tool\n"
    assert any(p.read_text() == original for p in (config / "opencode-nvim-backups").glob("*/opencode.jsonc"))
assert len(list((config / "opencode-nvim-backups").glob("*/opencode-nvim/package.json"))) == 1

# Each rejection must preserve both the installed plugin and every config byte.
for marker, contents in [
    ("permission", '{"permission":{"rg":"deny"}}'),
    ("neovim_apply_patch", '{"permissions":[{"action":"neovim_apply_patch","resource":"*","effect":"ask"}]}'),
    ("neovim_apply_patch", '{"agents":{"build":{"permissions":[{"action":"neovim_apply_patch","resource":"*","effect":"ask"}]}}}'),
    ("index.ts", '{"plugins":["./plugins/opencode-nvim/index.ts"]}'),
]:
    config_file.write_text(contents)
    before = snapshot(config)
    install(config, success=False, reason=marker)
    assert snapshot(config) == before, marker

# Presence alone is enough: an unsupported user-modified file must remain untouched.
config_file.write_text(original)
(config / "tool/rg.txt").write_text("Edited old tool\n")
before = snapshot(config)
install(config, success=False, reason="tool/rg.txt")
assert snapshot(config) == before

# Rejection on a profile without a plugin must not create one or a backup.
unsupported_config = profile / "unsupported"
(unsupported_config / "commands").mkdir(parents=True)
(unsupported_config / "commands/load_skills.md").write_text("Edited old command\n")
before = snapshot(unsupported_config)
install(unsupported_config, success=False, reason="commands/load_skills.md")
assert snapshot(unsupported_config) == before
print("Strict v2 installer, preservation, and reinstall passed:", profile)
