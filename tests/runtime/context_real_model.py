#!/usr/bin/env python3
"""Verify placeholders with an anonymous external model through real OpenCode.

Usage: python3 tests/runtime/context_real_model.py --model opencode/space-bunny-free --output /tmp/context-live
Uses a disposable profile with no inherited credentials or personal settings.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.request

from support import profile_environment, start_server, stop_server, wait_server


def run(cli, model, output):
    repo = Path(__file__).resolve().parents[2]
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="opencode-real-context-") as temporary:
        profile = Path(temporary).resolve()
        password = "context-real-model-fixture-password"
        env = {
            "PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
            "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_SERVER_USERNAME": "opencode",
            "OPENCODE_SERVER_PASSWORD": password, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
        }
        env.update(profile_environment(profile))
        project = profile / "project"
        project.mkdir()
        (Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json").write_text(json.dumps({
            "model": model, "snapshots": False, "update": "disable", "share": "disabled",
        }))
        version = subprocess.run([cli, "--version"], env=env, cwd=project,
                                 check=True, capture_output=True, text=True, timeout=20).stdout.strip()
        paths = subprocess.run([cli, "debug", "paths"], env=env, cwd=project,
                               check=True, capture_output=True, text=True, timeout=20).stdout.splitlines()
        assert paths and all(str(profile) in path for path in paths), paths
        process = None
        try:
            with (output / "server.log").open("w+") as log:
                process = start_server(cli, env=env, cwd=project, log=log)
                url = wait_server(process, log)
                headers = {"Authorization": "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()}
                provider_id, model_id = model.split("/", 1)
                deadline = time.monotonic() + 45
                while True:
                    with urllib.request.urlopen(urllib.request.Request(url + "/api/model", headers=headers), timeout=20) as reply:
                        catalog = json.load(reply)["data"]
                    selected = next((item for item in catalog if item["providerID"] == provider_id and item["id"] == model_id), None)
                    if selected:
                        break
                    assert time.monotonic() < deadline, f"Model unavailable without credentials: {model}"
                    time.sleep(0.2)
                result_path = output / "result.json"
                nvim_env = dict(env, OPENCODE_CONTEXT_PROJECT=str(project), OPENCODE_CONTEXT_URL=url,
                                OPENCODE_CONTEXT_MODEL=model, OPENCODE_CONTEXT_PASSWORD=password,
                                OPENCODE_CONTEXT_NONCE=secrets.token_hex(12), OPENCODE_CONTEXT_RESULT=str(result_path),
                                OPENCODE_CONTEXT_SCRIPT=str(repo / "tests/runtime/context_real_model.lua"))
                with (output / "nvim.log").open("w") as nvim_log:
                    check = subprocess.run(
                        ["nvim", "--headless", "--noplugin", "-n", "-i", "NONE",
                         "-u", str(repo / "tests/minimal_init.lua"),
                         "-c", "lua local ok, err = xpcall(function() dofile(vim.env.OPENCODE_CONTEXT_SCRIPT) end, debug.traceback); if not ok then print(err); vim.cmd('cquit 1') end",
                         "-c", "qa!"], env=nvim_env, cwd=repo, stdout=nvim_log, stderr=subprocess.STDOUT, timeout=720,
                    )
                assert check.returncode == 0, (output / "nvim.log").read_text()
                result = json.loads(result_path.read_text())
                assert len(result["cases"]) == 7, "Expected all seven placeholders"
                assert all(case.get("passed") for case in result["cases"]), "Model answers did not match every context"
                result.update(server_version=version, model=model, external_model=True)
                result_path.write_text(json.dumps(result, ensure_ascii=False, indent=2))
                return {"server_version": version, "model": model, "cases_passed": len(result["cases"]),
                        "evidence": str(result_path)}
        finally:
            stop_server(process)
            for name in ["server.log", "nvim.log", "result.json"]:
                path = output / name
                if path.exists():
                    path.write_text(path.read_text().replace(str(profile), "<PROFILE>"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=shutil.which("opencode"))
    parser.add_argument("--model", required=True, help="An anonymous model from the OpenCode catalog")
    parser.add_argument("--output", required=True, type=Path, help="New directory for synthetic test evidence")
    args = parser.parse_args()
    assert args.cli, "OpenCode executable not found"
    assert args.model.startswith("opencode/") and args.model.split("/", 1)[1], "Use an anonymous OpenCode model"
    print(json.dumps(run(str(Path(args.cli).resolve()), args.model, args.output.resolve()), indent=2))


if __name__ == "__main__":
    main()
