#!/usr/bin/env python3
"""Check context placeholders through real Neovim, OpenCode, and a local model.

Usage: python3 tests/runtime/context_backend.py [--cli /path/to/opencode]
Optional --output /new/directory retains sanitized requests and native history.
No personal configuration, credentials, or external model requests are used.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

import completion_backend as mock
from support import profile_environment, start_server, stop_server, wait_server


PROVIDER = "context-fixture"
MODEL = "fixture-code"
PASSWORD = "context-fixture-public-password"


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def run(cli, output=None):
    repo = Path(__file__).resolve().parents[2]
    provider = mock.Provider()
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="opencode-nvim-context-") as temporary:
            profile = Path(temporary).resolve()
            env = {
                "PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
                "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
                "OPENCODE_SERVER_USERNAME": "opencode", "OPENCODE_SERVER_PASSWORD": PASSWORD,
                "OPENCODE_CONTEXT_FIXTURE_KEY": "public-local-fixture-key",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            }
            env.update(profile_environment(profile))
            project = profile / "project"
            project.mkdir()
            config = {
                "model": f"{PROVIDER}/{MODEL}", "snapshots": False,
                "providers": {PROVIDER: {
                    "name": "Local context fixture", "env": ["OPENCODE_CONTEXT_FIXTURE_KEY"],
                    "package": "@opencode/ai/providers/openai",
                    "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1",
                                 "apiKey": "public-local-fixture-key", "transport": "http"},
                    "models": {MODEL: {
                        "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
                    }},
                }},
            }
            config_path = Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json"
            config_path.write_text(json.dumps(config))
            original_config = config_path.read_bytes()
            version = subprocess.run([cli, "--version"], env=env, cwd=project,
                                     check=True, capture_output=True, text=True, timeout=20).stdout.strip()
            paths = subprocess.run([cli, "debug", "paths"], env=env, cwd=project,
                                   check=True, capture_output=True, text=True, timeout=20).stdout.splitlines()
            assert paths and all(str(profile) in path for path in paths), paths
            process = None
            log_path = profile / "server.log"
            try:
                with log_path.open("w+") as log:
                    process = start_server(cli, env=env, cwd=project, log=log)
                    url = wait_server(process, log)
                    result_path = profile / "result.json"
                    nvim_env = dict(env, OPENCODE_CONTEXT_PROJECT=str(project),
                                    OPENCODE_CONTEXT_URL=url, OPENCODE_CONTEXT_MODEL=f"{PROVIDER}/{MODEL}",
                                    OPENCODE_CONTEXT_PASSWORD=PASSWORD, OPENCODE_CONTEXT_RESULT=str(result_path),
                                    OPENCODE_CONTEXT_SCRIPT=str(repo / "tests/runtime/context_placeholders.lua"))
                    check = subprocess.run(
                        ["nvim", "--headless", "--noplugin", "-n", "-i", "NONE",
                         "-u", str(repo / "tests/minimal_init.lua"),
                         "-c", "lua local ok, err = xpcall(function() dofile(vim.env.OPENCODE_CONTEXT_SCRIPT) end, debug.traceback); if not ok then print(err); vim.cmd('cquit 1') end",
                         "-c", "qa!"], env=nvim_env, cwd=repo,
                        capture_output=True, text=True, timeout=180,
                    )
                    assert check.returncode == 0, check.stdout + check.stderr
                    result = json.loads(result_path.read_text())
                    cases = result["cases"]
                    assert len(cases) >= 7, "Missing placeholder cases"
                    assert len({case["name"] for case in cases}) == len(cases), "Duplicate case labels"
                    assert len({case["session_id"] for case in cases}) == len(cases), "Cases must use fresh sessions"
                    assert len(provider.requests) == len(result["cases"]), \
                        (len(provider.requests), len(result["cases"]))
                    for case, request in zip(cases, provider.requests):
                        user_input = [item for item in request["body"]["input"] if item.get("role") == "user"]
                        prompt = "\n".join(strings(user_input[-1]))
                        assert all(text in prompt for text in [case["name"], *case["expected"]]), \
                            f"Context did not reach model: {case['name']}"
                    assert config_path.read_bytes() == original_config, "Server config changed"
                    result.update(version=version, model="loopback fixture", model_requests=len(provider.requests),
                                  model_context_verified=True)
                    if output:
                        output.mkdir(parents=True, exist_ok=False)
                        (output / "result.json").write_text(mock.evidence_json(result, profile))
                        (output / "model-requests.json").write_text(mock.evidence_json(provider.requests, profile))
                        (output / "nvim.log").write_text((check.stdout + check.stderr).replace(str(profile), "<PROFILE>"))
                        (output / "server.log").write_text(log_path.read_text().replace(str(profile), "<PROFILE>"))
                    return {"version": version, "cases": [case["name"] for case in result["cases"]],
                            "model_requests": len(provider.requests), "model_context_verified": True,
                            "model_transport": "loopback HTTP"}
            finally:
                stop_server(process)
    finally:
        provider.release_slow.set()
        provider.shutdown()
        provider.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=shutil.which("opencode"), help="OpenCode 2.0.11+ executable")
    parser.add_argument("--output", type=Path, help="New directory for sanitized evidence")
    args = parser.parse_args()
    assert args.cli, "OpenCode executable not found"
    assert args.output is None or not args.output.exists(), "Output directory already exists"
    print(json.dumps(run(str(Path(args.cli).resolve()), args.output), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
