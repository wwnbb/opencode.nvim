#!/usr/bin/env python3
"""Exercise native subsessions with isolated OpenCode, Neovim and a local model.

Two identical task descriptions deliberately prevent title-based child guesses.
No personal configuration, credentials or external model requests are used.
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
import urllib.request

from support import profile_environment, start_server, wait_server, stop_server


PROVIDER, MODEL = "subsession-fixture", "fixture-code"
PASSWORD = "opencode-nvim-test-only"


class ProviderHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append({"path": self.path, "body": body})
        assert self.path == "/v1/responses", self.path
        number = len(self.server.requests)
        inputs = body["input"]
        user = json.dumps([item for item in inputs if item.get("role") == "user"])
        completed_tools = any(item.get("type") == "function_call_output" for item in inputs)
        background = "SUBSESSION_BACKGROUND" in user
        if body.get("tools") and ("SUBSESSION_PARENT" in user or background) and not completed_tools:
            assert any(tool.get("name") == "subagent" for tool in body["tools"]), body["tools"]
            items = [{"id": f"item_{number}_{index}", "type": "function_call", "status": "completed",
                      "call_id": f"call_subsession_{index}", "name": "subagent",
                      "arguments": json.dumps({"agent": "general", "description": "Same task",
                          "prompt": "SUBSESSION_CHILD_" + name, "background": background,
                          "model": PROVIDER + "/" + MODEL})}
                     for index, name in enumerate(["INTERRUPTED", "FAILED"] if background else ["ONE", "TWO"], 1)]
        else:
            if not body.get("tools"):
                answer = "Subsession fixture"
            elif completed_tools:
                answer = "PARENT_DONE"
            else:
                answer = next(("CHILD_" + name for name in ["ONE", "TWO", "INTERRUPTED", "FAILED"]
                               if "SUBSESSION_CHILD_" + name in user), None)
            assert answer, user
            if answer.startswith("CHILD_"):
                release = self.server.release_background if answer in ["CHILD_INTERRUPTED", "CHILD_FAILED"] else self.server.release
                assert release.wait(120), "Child fixture was never released"
            if answer == "CHILD_FAILED":
                failure = json.dumps({"error": {"message": "Intentional subsession fixture failure",
                                                "type": "invalid_request_error", "code": "fixture_failure"}}).encode()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(failure)))
                self.end_headers()
                self.wfile.write(failure)
                return
            items = [{"id": f"item_{number}", "type": "message", "role": "assistant", "status": "completed",
                      "content": [{"type": "output_text", "text": answer, "annotations": []}]}]
        response_id = f"resp_{number}"
        events = [{"type": "response.created", "response": {"id": response_id, "status": "in_progress"}}]
        for index, item in enumerate(items):
            events.append({"type": "response.output_item.added", "output_index": index,
                           "item": {**item, "status": "in_progress",
                                    **({"arguments": ""} if item["type"] == "function_call" else {"content": []})}})
            delta = ({"type": "response.function_call_arguments.delta", "delta": item["arguments"]}
                     if item["type"] == "function_call" else
                     {"type": "response.output_text.delta", "content_index": 0, "delta": answer})
            events.append({**delta, "item_id": item["id"], "output_index": index})
            events.append({"type": "response.output_item.done", "output_index": index, "item": item})
        events.append({"type": "response.completed", "response": {"id": response_id, "status": "completed",
                       "output": items, "usage": {"input_tokens": 12, "output_tokens": 3, "total_tokens": 15}}})
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            for sequence, event in enumerate(events):
                event["sequence_number"] = sequence
                self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def check_server_scope(cli, env, project, profile, owner_url, warm):
    authorization = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()

    def read(url, path):
        request = urllib.request.Request(url + path, headers={"Authorization": authorization})
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)["data"]

    parent = warm["parent"]
    expected = {parent, *warm["tasks"].values()}
    process = None
    with (profile / "second-server.log").open("w+") as log:
        try:
            process = start_server(cli, env=env, cwd=project, log=log)
            other_url = wait_server(process, log)
            owner_active = read(owner_url, "/api/session/active")
            other_active = read(other_url, "/api/session/active")
            assert expected <= owner_active.keys(), owner_active
            assert other_active == {}, other_active
            owner_history = read(owner_url, "/api/session/" + parent + "/message")
            other_history = read(other_url, "/api/session/" + parent + "/message")
            assert owner_history == other_history, "Servers did not share the same durable history"
            children = [read(url, "/api/session?parentID=" + parent) for url in [owner_url, other_url]]
            assert {child["id"] for child in children[0]} == {child["id"] for child in children[1]} == expected - {parent}
            result = {"owner_active": owner_active, "second_active": other_active,
                      "same_parent_history": True, "same_children": sorted(expected - {parent}),
                      "shared_profile": True, "activity_is_server_local": True}
        finally:
            stop_server(process)
    assert expected <= read(owner_url, "/api/session/active").keys(), "Stopping the second server disturbed its owner"
    return result


def run(cli, output):
    repo = Path(__file__).resolve().parents[2]
    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProviderHandler)
    provider.daemon_threads, provider.requests, provider.release = True, [], threading.Event()
    provider.release_background = threading.Event()
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="opencode-nvim-subsessions-") as temporary:
        profile = Path(temporary).resolve()
        env = {"PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
               "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
               "OPENCODE_SERVER_USERNAME": "opencode", "OPENCODE_SERVER_PASSWORD": PASSWORD,
               "OPENCODE_SUBSESSION_FIXTURE_KEY": "public-local-fixture-key",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        env.update(profile_environment(profile))
        project = profile / "project"
        project.mkdir()
        config = {"model": PROVIDER + "/" + MODEL, "snapshots": False,
                  "providers": {PROVIDER: {"name": "Local subsession fixture",
                    "env": ["OPENCODE_SUBSESSION_FIXTURE_KEY"], "package": "@opencode/ai/providers/openai",
                    "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1",
                                 "apiKey": "public-local-fixture-key", "transport": "http"},
                    "models": {MODEL: {"capabilities": {"tools": True, "input": ["text"], "output": ["text"]}}}}}}
        (Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json").write_text(json.dumps(config))
        process, result = None, None
        try:
            version = subprocess.run([cli, "--version"], env=env, cwd=project, check=True,
                                     capture_output=True, text=True, timeout=20).stdout.strip()
            paths = subprocess.run([cli, "debug", "paths"], env=env, cwd=project, check=True,
                                   capture_output=True, text=True, timeout=20).stdout.splitlines()
            assert paths and all(str(profile) in path for path in paths), paths
            with (profile / "server.log").open("w+") as log:
                process = start_server(cli, env=env, cwd=project, log=log)
                url = wait_server(process, log)
                results = {}
                for phase in ["warm", "cold", "completed", "background", "background-completed"]:
                    if phase == "completed":
                        provider.release.set()
                    if phase == "background-completed":
                        provider.release_background.set()
                    nvim = subprocess.run(["nvim", "--headless", "--noplugin", "-n", "-i", "NONE",
                                           "-u", str(repo / "tests/minimal_init.lua"),
                                           "-l", str(repo / "tests/runtime/subsession_lifecycle.lua")],
                                          env=dict(env, OPENCODE_V2_SERVER_URL=url, OPENCODE_V2_PROJECT=str(project),
                                                   OPENCODE_V2_MODEL=PROVIDER + "/" + MODEL,
                                                   OPENCODE_SUBSESSION_PHASE=phase,
                                                   OPENCODE_SUBSESSION_PROFILE=str(profile)),
                                          cwd=repo, capture_output=True, text=True, timeout=90)
                    (profile / (phase + ".log")).write_text(nvim.stdout + nvim.stderr)
                    assert nvim.returncode == 0, nvim.stdout + nvim.stderr
                    results[phase] = json.loads((profile / (phase + ".json")).read_text())
                    if phase == "warm":
                        server_scope = check_server_scope(cli, env, project, profile, url, results[phase])
                        (profile / "server-scope.json").write_text(json.dumps(server_scope, indent=2) + "\n")
                result = {"version": version, "model_requests": len(provider.requests),
                          "real_provider_requests": 0, "phases": results, "server_scope": server_scope}
                return result
        finally:
            provider.release.set()
            provider.release_background.set()
            stop_server(process)
            provider.shutdown()
            provider.server_close()
            if output:
                output.mkdir(parents=True, exist_ok=False)
                for path in profile.glob("*.log"):
                    (output / path.name).write_text(path.read_text().replace(str(profile), "<PROFILE>"))
                for path in profile.glob("*.json"):
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
    print(json.dumps({key: value for key, value in result.items() if key != "phases"}, indent=2))
