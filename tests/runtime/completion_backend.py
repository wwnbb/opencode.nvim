#!/usr/bin/env python3
"""Verify ghost-text generation against a real OpenCode and a loopback mock model.

Usage: python3 tests/runtime/completion_backend.py --cli /path/to/opencode
Optional --output /new/directory retains sanitized request/result evidence.
No credentials or configuration are inherited; every model request goes to the
fixture's local HTTP server. Requires Neovim to exercise the actual Lua profile.
"""

import argparse
import base64
import http.client
import http.server
import json
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from support import profile_environment, start_server, wait_server, stop_server


PROVIDER = "completion-fixture"
MODEL = "fixture-code"
PASSWORD = "completion-fixture-public-password"
ANSWER = "fixture_completion()"


class Provider(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), ProviderHandler)
        self.requests = []
        self.slow_started = threading.Event()
        self.slow_cancelled = threading.Event()
        self.release_slow = threading.Event()


class ProviderHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append({"path": self.path, "body": body,
                                     "fixture_header": self.headers.get("X-Completion-Fixture")})
        assert self.path == "/v1/responses", self.path
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            if "CANCEL_FIXTURE" in json.dumps(body.get("input")):
                self.server.slow_started.set()
                while not self.server.release_slow.wait(0.03):
                    readable, _, _ = select.select([self.connection], [], [], 0)
                    if readable and not self.connection.recv(1, socket.MSG_PEEK):
                        self.server.slow_cancelled.set()
                        return
                    self.wfile.write(b": fixture waiting\n\n")
                    self.wfile.flush()
            response_id, item_id = "resp_fixture", "msg_fixture"
            item = {"id": item_id, "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": ANSWER, "annotations": []}]}
            events = [
                {"type": "response.created", "response": {"id": response_id, "status": "in_progress"}},
                {"type": "response.output_item.added", "output_index": 0,
                 "item": {"id": item_id, "type": "message", "role": "assistant", "content": []}},
                *({"type": "response.output_text.delta", "item_id": item_id, "output_index": 0,
                   "content_index": 0, "delta": chunk}
                  for chunk in getattr(self.server, "answer_chunks", [ANSWER])),
                {"type": "response.output_item.done", "output_index": 0, "item": item},
                {"type": "response.completed", "response": {"id": response_id, "status": "completed",
                 "output": [item], "usage": {"input_tokens": 12, "output_tokens": 3, "total_tokens": 15}}},
            ]
            for number, event in enumerate(events):
                event["sequence_number"] = number
                self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
                if event["type"] == "response.output_text.delta":
                    self.wfile.flush()
                    time.sleep(getattr(self.server, "chunk_delay", 0))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            if self.server.slow_started.is_set():
                self.server.slow_cancelled.set()


def prepare_profile(repo, profile, env):
    """Use the shipped Lua config compiler, including preservation of JSONC."""
    config = {"enabled": True, "model": {"providerID": PROVIDER, "modelID": MODEL},
              "options": {"settings": {"reasoningEffort": "none"},
                          "body": {"max_output_tokens": 128},
                          "headers": {"X-Completion-Fixture": "completion"}}}
    existing = {"providers": {PROVIDER: {"models": {MODEL: {"variants": [
        {"id": "ordinary-variant", "settings": {"reasoningEffort": "medium"},
         "body": {"max_output_tokens": 384}}]}}}}}
    (profile / "completion-config.json").write_text(json.dumps(config))
    (profile / "existing.jsonc").write_text("// Existing inline settings must survive.\n" + json.dumps(existing))
    script = profile / "prepare.lua"
    script.write_text("""vim.opt.shadafile = 'NONE'
vim.opt.runtimepath:append(vim.env.OPENCODE_COMPLETION_REPO)
local function read(name)
  return table.concat(vim.fn.readfile(vim.env.OPENCODE_COMPLETION_PROFILE .. '/' .. name), '\\n')
end
local config = vim.json.decode(read('completion-config.json'))
local profile = require('opencode.completion.profile')
local content, active, err = profile.prepare(config, read('existing.jsonc'))
assert(not err, err)
local model, resolve_err = profile.resolve(config, { managed = true, active = active })
assert(model, resolve_err)
vim.fn.writefile({vim.json.encode({content = content, model = model})},
  vim.env.OPENCODE_COMPLETION_PROFILE .. '/prepared.json')
""")
    nvim_env = dict(env, OPENCODE_COMPLETION_REPO=str(repo), OPENCODE_COMPLETION_PROFILE=str(profile),
                    OPENCODE_COMPLETION_SCRIPT=str(script))
    subprocess.run(["nvim", "--headless", "--noplugin", "-u", "NONE", "-i", "NONE",
                    "-c", "lua dofile(vim.env.OPENCODE_COMPLETION_SCRIPT)", "-c", "qa!"],
                   env=nvim_env, cwd=profile, check=True, capture_output=True, timeout=15)
    return json.loads((profile / "prepared.json").read_text())


def evidence_json(value, profile):
    text = json.dumps(value, ensure_ascii=False, indent=2)
    for path in [str(profile), urllib.parse.quote(str(profile), safe="")]:
        text = text.replace(path, "<PROFILE>")
    return text + "\n"


def run_streaming_client(repo, profile, env, url):
    script = profile / "streaming.lua"
    script.write_text(r"""vim.opt.shadafile = 'NONE'
vim.opt.swapfile = false
vim.opt.runtimepath:append(vim.env.OPENCODE_COMPLETION_REPO)
local directory = vim.env.OPENCODE_COMPLETION_PROFILE
local prepared = vim.json.decode(table.concat(vim.fn.readfile(directory .. '/prepared.json'), '\n'))
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'local result = ' })
vim.api.nvim_win_set_cursor(0, { 1, 7 })
local before = vim.api.nvim_buf_get_lines(source, 0, -1, false)
local cursor = vim.api.nvim_win_get_cursor(0)
local client = require('opencode.client')
client.setup({ url = vim.env.OPENCODE_COMPLETION_URL,
  auth = { username = 'opencode', password = vim.env.OPENCODE_SERVER_PASSWORD }, reconnect = false })
client.connect_events()
assert(vim.wait(5000, function() return client.sse.is_connected() end, 10), 'SSE did not connect')
local done, err, answer, updates = false, nil, nil, {}
local handle = client.generate_completion('STREAM_COMPLETION_CONTEXT', prepared.model,
  function(request_error, text) err, answer, done = request_error, text, true end,
  { timeout = 10000, directory = directory .. '/project', on_update = function(text)
    assert(not done, 'Text update arrived after completion')
    assert(type(text) == 'string' and text ~= '', 'Empty streaming completion')
    updates[#updates + 1] = text
    assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(source, 0, -1, false)), 'Source buffer changed')
    assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(0)), 'Source cursor moved')
  end })
assert(handle and type(handle.cancel) == 'function')
assert(vim.wait(15000, function() return done end, 10), 'Completion request timed out')
assert(not err, vim.inspect(err))
assert(answer == vim.env.OPENCODE_COMPLETION_ANSWER, vim.inspect(answer))
local partials, previous = 0, ''
for _, text in ipairs(updates) do
  assert(text:sub(1, #previous) == previous, 'Text updates were not cumulative')
  assert(answer:sub(1, #text) == text, 'Text update did not match final completion')
  if #text > #previous and #text < #answer then partials = partials + 1 end
  previous = text
end
assert(partials >= 2 and previous == answer, 'Completion text was not streamed: ' .. vim.inspect(updates))
assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(source, 0, -1, false)), 'Source buffer changed')
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(0)), 'Source cursor moved')
local cleaned, checking = false, false
assert(vim.wait(5000, function()
  if not cleaned and not checking then
    checking = true
    require('opencode.client.v2').request('session_list', {
      query = { location = { directory = directory .. '/project' } },
    }, function(list_error, sessions)
      assert(not list_error, vim.inspect(list_error))
      cleaned, checking = true, false
      for _, session in ipairs(sessions) do
        if client.is_explanation_session(session.id) then cleaned = false end
      end
    end)
  end
  return cleaned
end, 20), 'Completion left a temporary session behind')
client.disconnect_events()
vim.fn.writefile({vim.json.encode({answer = answer, updates = updates,
  source_unchanged = true, cursor_unchanged = true, temporary_sessions_cleaned = true})},
  directory .. '/streaming-result.json')
""")
    completed = subprocess.run(
        ["nvim", "--headless", "--noplugin", "-u", "NONE", "-i", "NONE",
         "-c", "lua dofile(vim.env.OPENCODE_COMPLETION_SCRIPT)", "-c", "qa!"],
        env=dict(env, OPENCODE_COMPLETION_REPO=str(repo), OPENCODE_COMPLETION_PROFILE=str(profile),
                 OPENCODE_COMPLETION_SCRIPT=str(script), OPENCODE_COMPLETION_URL=url,
                 OPENCODE_COMPLETION_ANSWER=ANSWER),
        cwd=profile / "project", capture_output=True, text=True, timeout=30)
    assert completed.returncode == 0, completed.stdout + completed.stderr
    result_path = profile / "streaming-result.json"
    assert result_path.exists(), completed.stdout + completed.stderr
    return json.loads(result_path.read_text())


def run(cli, output):
    repo = Path(__file__).resolve().parents[2]
    provider = Provider()
    provider_thread = threading.Thread(target=provider.serve_forever, daemon=True)
    provider_thread.start()
    with tempfile.TemporaryDirectory(prefix="opencode-nvim-completion-") as temporary:
        profile = Path(temporary).resolve()
        env = {"PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
               "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
               "OPENCODE_SERVER_USERNAME": "opencode", "OPENCODE_SERVER_PASSWORD": PASSWORD,
               "OPENCODE_COMPLETION_FIXTURE_KEY": "public-local-fixture-key",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        env.update(profile_environment(profile))
        project = profile / "project"
        project.mkdir()
        base_model = {"providerID": PROVIDER, "id": MODEL}
        config = {"model": PROVIDER + "/" + MODEL, "snapshots": False,
                  "providers": {PROVIDER: {"name": "Local fixture only", "env": ["OPENCODE_COMPLETION_FIXTURE_KEY"],
                  "package": "@opencode/ai/providers/openai",
                  "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1",
                               "apiKey": "public-local-fixture-key", "transport": "http"},
                  "models": {MODEL: {"settings": {"reasoningEffort": "high"},
                    "body": {"max_output_tokens": 768}, "headers": {"X-Completion-Fixture": "ordinary"},
                    "capabilities": {"tools": True, "input": ["text"], "output": ["text"]}}}}}}
        config_path = Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json"
        config_path.write_text(json.dumps(config))
        original_config = config_path.read_bytes()
        prepared = prepare_profile(repo, profile, env)
        env["OPENCODE_CONFIG_CONTENT"] = prepared["content"]
        version = subprocess.run([cli, "--version"], env=env, cwd=project, check=True,
                                 capture_output=True, text=True, timeout=20).stdout.strip()
        paths = subprocess.run([cli, "debug", "paths"], env=env, cwd=project, check=True,
                               capture_output=True, text=True, timeout=20).stdout.splitlines()
        assert all(str(profile) in path for path in paths), paths
        authorization = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()
        exchanges = []
        result = None
        process = None
        log_path = profile / "server.log"
        try:
            with log_path.open("w+") as log:
                process = start_server(cli, env=env, cwd=project, log=log)
                url = wait_server(process, log)

                def request(method, path, body=None, allow_error=False):
                    req = urllib.request.Request(url + path, method=method,
                        headers={"Authorization": authorization, "Content-Type": "application/json"},
                        data=None if body is None else json.dumps(body).encode())
                    try:
                        response = urllib.request.urlopen(req, timeout=20)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        raw = response.read().decode()
                        data = json.loads(raw) if raw else None
                        exchanges.append({"method": method, "path": path, "request": body,
                                          "status": response.status, "response": data})
                        assert allow_error or 200 <= response.status < 300, (response.status, data)
                        return data

                # The base runtime initializes lazily. Retry only model selection
                # failures: they happen before generation and cannot duplicate it.
                cold_start = time.monotonic()
                cold_attempts = []
                while True:
                    reply = request("POST", "/api/experimental/generate", {
                        "prompt": "COLD_COMPLETION", "model": prepared["model"]}, allow_error=True)
                    cold_attempts.append({"elapsed_ms": round((time.monotonic() - cold_start) * 1000),
                                          "status": exchanges[-1]["status"], "response": reply})
                    if reply == {"data": {"text": ANSWER}}:
                        break
                    assert exchanges[-1]["status"] == 400 and reply.get("_tag") == "InvalidRequestError", reply
                    assert reply["message"] in [f"Model unavailable: {PROVIDER}/{MODEL}",
                        f"Variant unavailable for {PROVIDER}/{MODEL}: " + prepared["model"]["variant"]], reply
                    assert time.monotonic() - cold_start < 3, cold_attempts
                    time.sleep(0.05)
                assert len(provider.requests) == 1, "Model-selection retry duplicated provider work"
                assert provider.requests[0]["body"]["reasoning"]["effort"] == "none", provider.requests[0]
                assert provider.requests[0]["body"]["max_output_tokens"] == 128, provider.requests[0]

                location = "?" + urllib.parse.urlencode({"location[directory]": str(project)})
                request("GET", "/api/config" + location)
                deadline = time.monotonic() + 5
                while True:
                    models = request("GET", "/api/model" + location)["data"]
                    if any(model["providerID"] == PROVIDER and model["id"] == MODEL for model in models):
                        break
                    assert time.monotonic() < deadline, "Project model was never ready"
                    time.sleep(0.05)
                session = request("POST", "/api/session", {"title": "Completion isolation fixture",
                    "location": {"directory": str(project)}, "model": base_model})["data"]
                prefix = "/api/session/" + session["id"]
                request("POST", prefix + "/prompt", {"text": "SENT_HISTORY_SENTINEL"})
                deadline = time.monotonic() + 10
                while True:
                    history = request("GET", prefix + "/message")["data"]
                    if any(message.get("type") == "idle" for message in history):
                        break
                    assert time.monotonic() < deadline, history
                    time.sleep(0.05)
                assert ANSWER in json.dumps(history), history
                # Preserve both actual chat history and an admitted queued turn.
                request("POST", prefix + "/prompt", {"text": "UNSENT_HISTORY_SENTINEL", "resume": False})
                before = {"sessions": request("GET", "/api/session" + location),
                          "messages": request("GET", prefix + "/message"),
                          "inbox": request("GET", prefix + "/inbox")}

                def generate(label, model):
                    count = len(provider.requests)
                    reply = request("POST", "/api/experimental/generate", {"prompt": label, "model": model})
                    assert reply == {"data": {"text": ANSWER}}, reply
                    assert len(provider.requests) == count + 1, provider.requests[count:]
                    captured = provider.requests[-1]
                    assert not captured["body"].get("tools"), captured
                    assert label in json.dumps(captured["body"]["input"]), captured
                    assert "HISTORY_SENTINEL" not in json.dumps(captured), captured
                    return captured

                ordinary_before = generate("ORDINARY_BEFORE", base_model)
                completion = generate("COMPLETION_CONTEXT", prepared["model"])
                preserved_variant = generate("PRESERVED_VARIANT", {**base_model, "variant": "ordinary-variant"})
                ordinary_after = generate("ORDINARY_AFTER", base_model)
                for captured in [ordinary_before, ordinary_after]:
                    assert captured["body"]["reasoning"]["effort"] == "high", captured
                    assert captured["body"]["max_output_tokens"] == 768, captured
                    assert captured["fixture_header"] == "ordinary", captured
                assert completion["body"]["reasoning"]["effort"] == "none", completion
                assert completion["body"]["max_output_tokens"] == 128, completion
                assert completion["fixture_header"] == "completion", completion
                assert preserved_variant["body"]["reasoning"]["effort"] == "medium", preserved_variant
                assert preserved_variant["body"]["max_output_tokens"] == 384, preserved_variant

                provider.answer_chunks = [ANSWER[:4], ANSWER[4:8], ANSWER[8:]]
                provider.chunk_delay = 0.15
                count = len(provider.requests)
                streaming = run_streaming_client(repo, profile, env, url)
                assert len(provider.requests) == count + 1, provider.requests[count:]
                streamed = provider.requests[-1]
                assert not streamed["body"].get("tools"), streamed
                assert "STREAM_COMPLETION_CONTEXT" in json.dumps(streamed["body"]["input"]), streamed
                assert "HISTORY_SENTINEL" not in json.dumps(streamed), streamed
                assert streamed["body"]["reasoning"]["effort"] == "none", streamed
                assert streamed["body"]["max_output_tokens"] == 128, streamed
                assert streamed["fixture_header"] == "completion", streamed
                provider.chunk_delay = 0

                parsed = urllib.parse.urlparse(url)
                cancelled = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=10)
                cancelled.request("POST", "/api/experimental/generate",
                    body=json.dumps({"prompt": "CANCEL_FIXTURE", "model": prepared["model"]}),
                    headers={"Authorization": authorization, "Content-Type": "application/json"})
                assert provider.slow_started.wait(10), "Mock provider did not receive cancellable request"
                cancelled.sock.shutdown(socket.SHUT_RDWR)
                cancelled.close()
                propagated = provider.slow_cancelled.wait(3)
                provider.release_slow.set()
                after = {"sessions": request("GET", "/api/session" + location),
                         "messages": request("GET", prefix + "/message"),
                         "inbox": request("GET", prefix + "/inbox")}
                assert before == after, "Completion altered session history, list, or inbox"
                assert config_path.read_bytes() == original_config, "Inline model options rewrote config"
                result = {"version": version, "route": "/api/experimental/generate", "mock_model_requests": len(provider.requests),
                    "uses_lua_profile": True, "private_variant": prepared["model"]["variant"],
                    "reasoning_effort": completion["body"]["reasoning"]["effort"], "max_output_tokens": 128,
                    "ordinary_model_unchanged": True, "existing_variant_preserved": True,
                    "session_list_history_inbox_unchanged": True, "config_file_unchanged": True,
                    "preserved_history_messages": len(before["messages"]["data"]),
                    "http_cancellation_reached_provider": propagated, "real_provider_requests": 0}
                result["cold_start_attempts"] = cold_attempts
                result["streaming_completion"] = streaming
                return result
        finally:
            provider.release_slow.set()
            stop_server(process)
            provider.shutdown()
            provider.server_close()
            if output:
                output.mkdir(parents=True, exist_ok=False)
                if log_path.exists():
                    (output / "server.log").write_text(log_path.read_text().replace(str(profile), "<PROFILE>"))
                for index, path in enumerate(profile.rglob("*.log")):
                    if path != log_path:
                        (output / f"native-{index}.log").write_text(path.read_text().replace(str(profile), "<PROFILE>"))
                for name, value in {"exchanges.json": exchanges, "requests.json": provider.requests,
                                    "result.json": result}.items():
                    (output / name).write_text(evidence_json(value, profile))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=shutil.which("opencode"), help="OpenCode 2.0.11+ executable")
    parser.add_argument("--output", type=Path, help="New directory for sanitized evidence")
    args = parser.parse_args()
    assert args.cli, "OpenCode executable not found"
    assert not args.output or not args.output.exists(), "Output directory must be new"
    result = run(str(Path(args.cli).resolve()), args.output)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
