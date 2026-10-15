#!/usr/bin/env python3
"""Install prepared tools and exercise real edit approval without Node/npm/Bun.

Uses a disposable profile and a loopback model fixture; no provider credentials
or user configuration are inherited. Requires OpenCode 2.0.26+ and Neovim.
"""

import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

from support import profile_environment, start_server, wait_server, stop_server


PROVIDER, MODEL = "review-fixture", "fixture-code"
PASSWORD = "opencode-nvim-test-only"


class ProviderHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append({"path": self.path, "body": body})
        assert self.path == "/v1/responses", self.path
        inputs = body["input"]
        number = len(self.server.requests)
        item_id = f"item_fixture_{number}"
        if not body.get("tools") or any(item.get("type") == "function_call_output" for item in inputs):
            item = {"id": item_id, "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": "Review finished.", "annotations": []}]}
            delta = {"type": "response.output_text.delta", "content_index": 0, "delta": "Review finished."}
        else:
            prompt = json.dumps(inputs)
            name = "neovim_edit"
            target = next((name for name in ["interrupted-review", "denied-review", "rejected-review", "patched-review"]
                           if name + ".txt" in prompt), "review")
            arguments = {"path": target + ".txt", "oldString": "before", "newString": "after"}
            if target == "patched-review":
                name = "neovim_patch"
                arguments = {"patchText": "*** Begin Patch\n*** Update File: patched-review.txt\n@@\n-before\n+after\n*** End Patch"}
            assert any(tool.get("name") == name for tool in body["tools"]), body["tools"]
            item = {"id": item_id, "type": "function_call", "status": "completed",
                    "call_id": f"call_fixture_{number}", "name": name, "arguments": json.dumps(arguments)}
            delta = {"type": "response.function_call_arguments.delta", "delta": item["arguments"]}
        response_id = f"resp_fixture_{number}"
        events = [
            {"type": "response.created", "response": {"id": response_id, "status": "in_progress"}},
            {"type": "response.output_item.added", "output_index": 0,
             "item": {**item, "status": "in_progress", **({"arguments": ""} if item["type"] == "function_call" else {"content": []})}},
            {**delta, "item_id": item_id, "output_index": 0},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {"id": response_id, "status": "completed", "output": [item],
             "usage": {"input_tokens": 12, "output_tokens": 3, "total_tokens": 15}}},
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        for sequence, event in enumerate(events):
            event["sequence_number"] = sequence
            self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
        self.wfile.flush()


def run(cli, output):
    repo = Path(__file__).resolve().parents[2]
    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProviderHandler)
    provider.daemon_threads = True
    provider.requests = []
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="opencode-nvim-prepared-tools-") as temporary:
        profile = Path(temporary).resolve()
        binaries = profile / "bin"
        binaries.mkdir()
        for name in ["nvim", "bash", "dirname", "rg", "git", "cp"]:
            executable = shutil.which(name)
            assert executable, f"Missing fixture prerequisite: {name}"
            (binaries / name).symlink_to(executable)
        env = {"PATH": str(binaries), "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
               "HOME": str(profile / "home"), "OPENCODE_DISABLE_MODELS_FETCH": "1",
               "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_SERVER_USERNAME": "opencode",
               "OPENCODE_SERVER_PASSWORD": PASSWORD, "OPENCODE_REVIEW_FIXTURE_KEY": "public-local-fixture-key",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        env.update(profile_environment(profile))
        assert all(shutil.which(name, path=env["PATH"]) is None for name in ["node", "npm", "bun"])
        project = profile / "project"
        project.mkdir()
        config_dir = Path(env["OPENCODE_CONFIG_DIR"])
        config = {"model": PROVIDER + "/" + MODEL, "snapshots": False,
                  "providers": {PROVIDER: {"name": "Local fixture only", "env": ["OPENCODE_REVIEW_FIXTURE_KEY"],
                  "package": "@opencode/ai/providers/openai",
                  "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1",
                               "apiKey": "public-local-fixture-key", "transport": "http"},
                  "models": {MODEL: {"capabilities": {"tools": True, "input": ["text"], "output": ["text"]}}}}}}
        (config_dir / "opencode.json").write_text(json.dumps(config))
        process, result = None, None
        log_path = profile / "server.log"
        try:
            installed = subprocess.run([str(repo / "scripts/install-tools.sh"), str(config_dir)],
                                       env=env, cwd=repo, capture_output=True, text=True, timeout=30)
            (profile / "install.log").write_text(installed.stdout + installed.stderr)
            assert installed.returncode == 0, installed.stdout + installed.stderr
            plugin = config_dir / "plugins/opencode-nvim"
            assert (plugin / "index.js").is_file(), "Installer did not copy the prepared bundle"
            assert not list(plugin.rglob("node_modules")), "Installer copied npm dependencies"
            assert not (plugin / "package-lock.json").exists(), "Installer copied the development lockfile"
            manifest = json.loads((plugin / "package.json").read_text())
            assert not manifest.get("dependencies"), manifest
            version = subprocess.run([cli, "--version"], env=env, cwd=project, check=True,
                                     capture_output=True, text=True, timeout=20).stdout.strip()
            paths = subprocess.run([cli, "debug", "paths"], env=env, cwd=project, check=True,
                                   capture_output=True, text=True, timeout=20).stdout.splitlines()
            assert all(str(profile) in path for path in paths), paths
            with log_path.open("w+") as log:
                process = start_server(cli, env=env, cwd=project, log=log)
                url = wait_server(process, log)
                authorization = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()
                location = "?" + urllib.parse.urlencode({"location[directory]": str(project)})
                deadline = time.monotonic() + 10
                while True:
                    request = urllib.request.Request(url + "/api/model" + location,
                                                     headers={"Authorization": authorization})
                    with urllib.request.urlopen(request, timeout=20) as response:
                        models = json.load(response)["data"]
                    if any(model["providerID"] == PROVIDER and model["id"] == MODEL for model in models):
                        break
                    assert time.monotonic() < deadline, "Fixture model did not become ready"
                    time.sleep(0.05)
                nvim = subprocess.run([str(binaries / "nvim"), "--headless", "--noplugin", "-n", "-i", "NONE",
                                       "-u", str(repo / "tests/minimal_init.lua"),
                                       "-l", str(repo / "tests/runtime/v2_review.lua")],
                                      env=dict(env, OPENCODE_V2_SERVER_URL=url, OPENCODE_V2_PROJECT=str(project),
                                               OPENCODE_V2_MODEL=PROVIDER + "/" + MODEL,
                                               OPENCODE_V2_VERSION=version,
                                               OPENCODE_V2_OUTPUT=str(profile / "review.json")),
                                      cwd=repo, capture_output=True, text=True, timeout=180)
                (profile / "nvim.log").write_text(nvim.stdout + nvim.stderr)
                assert nvim.returncode == 0, nvim.stdout + nvim.stderr
                review = json.loads((profile / "review.json").read_text())
                result = {"version": version, "node_npm_bun_absent": True,
                          "installed_bundle_has_no_dependencies": True,
                          "model_requests": len(provider.requests), "real_provider_requests": 0,
                          "passed": ["native permission", "edit approval", "pending review reconnect",
                                     "interruption and late reply refusal", "native deny", "edit rejection", "patch approval"],
                          "review": review}
                return result
        finally:
            stop_server(process)
            provider.shutdown()
            provider.server_close()
            if output:
                output.mkdir(parents=True, exist_ok=False)
                for path in profile.glob("*.log"):
                    (output / path.name).write_text(path.read_text().replace(str(profile), "<PROFILE>"))
                for name, value in {"requests.json": provider.requests, "result.json": result}.items():
                    (output / name).write_text(json.dumps(value, indent=2).replace(str(profile), "<PROFILE>") + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=shutil.which("opencode"))
    parser.add_argument("--output", type=Path, help="New directory for sanitized evidence")
    args = parser.parse_args()
    assert args.cli, "OpenCode executable not found"
    assert not args.output or not args.output.exists(), "Output directory must be new"
    result = run(str(Path(args.cli).resolve()), args.output)
    print(json.dumps({key: value for key, value in result.items() if key != "review"}, indent=2))
