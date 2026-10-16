#!/usr/bin/env python3
"""Exercise Visual explanation against OpenCode and a loopback-only mock model.

Usage: python3 tests/runtime/explanation_backend.py --cli /path/to/opencode

The fixture isolates OpenCode's config, data, state, and cache directories. It
uses Neovim to build the real explanation prompt and two private model variants,
then streams the explanation through the plugin's native SSE client. No account secrets
or external model requests are used.
It also saves model/reasoning preferences and checks subsequent provider payloads.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from support import profile_environment, start_server, wait_server, stop_server

import completion_backend as mock


PROVIDER = "explanation-fixture"
MODEL = "fixture-code"
PASSWORD = "explanation-fixture-public-password"
ANSWER = "L24–27 — Initializes a total and updates it in one loop."


def run_nvim(repo, profile, env, script):
    script_path = profile / "check.lua"
    script_path.write_text(script)
    subprocess.run(
        ["nvim", "--headless", "--noplugin", "-u", "NONE", "-i", "NONE",
         "-c", "lua dofile(vim.env.EXPLANATION_CHECK_SCRIPT)", "-c", "qa!"],
        env=dict(env, EXPLANATION_CHECK_SCRIPT=str(script_path),
                 EXPLANATION_REPO=str(repo), EXPLANATION_PROFILE=str(profile)),
        cwd=profile,
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )


def prepare(repo, profile, env):
    features = {
        "completion": {
            "enabled": True,
            "model": {"providerID": PROVIDER, "modelID": MODEL},
            "options": {"settings": {"reasoningEffort": "medium"},
                        "body": {"max_output_tokens": 96},
                        "headers": {"X-Completion-Fixture": "completion"}},
        },
        "explanation": {
            "enabled": True,
            "model": {"providerID": PROVIDER, "modelID": MODEL},
            "options": {"settings": {"reasoningEffort": "none"},
                        "body": {"max_output_tokens": 128},
                        "headers": {"X-Completion-Fixture": "explanation"}},
            "language": "en",
        },
    }
    (profile / "features.json").write_text(json.dumps(features))
    (profile / "existing.jsonc").write_text(
        "// Keep the ordinary model and its preexisting variant.\n"
        + json.dumps({"providers": {PROVIDER: {"models": {MODEL: {"variants": [
            {"id": "ordinary-variant", "settings": {"reasoningEffort": "high"}},
            {"id": "none", "settings": {"reasoningEffort": "none"}},
            {"id": "low", "settings": {"reasoningEffort": "low"}},
        ]}}}}})
    )
    run_nvim(repo, profile, env, r"""
vim.opt.runtimepath:append(vim.env.EXPLANATION_REPO)
local directory = vim.env.EXPLANATION_PROFILE
local function read(name)
  return table.concat(vim.fn.readfile(directory .. '/' .. name), '\n')
end
local features = vim.json.decode(read('features.json'))
local profile = require('opencode.completion.profile')
local overlay, completion_active, completion_error = profile.prepare(
  features.completion, read('existing.jsonc'), 'completion')
assert(not completion_error, completion_error)
local explanation_active, explanation_error
overlay, explanation_active, explanation_error = profile.prepare(
  features.explanation, overlay, 'explanation')
assert(not explanation_error, explanation_error)
assert(completion_active.variant ~= explanation_active.variant)
local completion_model = assert(profile.resolve(features.completion,
  { managed = true, active = completion_active }, 'completion'))
local explanation_model = assert(profile.resolve(features.explanation,
  { managed = true, active = explanation_active }, 'explanation'))

local lines = {}
for index = 1, 23 do lines[index] = '-- surrounding line ' .. index end
lines[24] = 'local total = 0'
lines[25] = 'for _, amount in ipairs(amounts) do'
lines[26] = '  total = total + amount'
lines[27] = 'end'
lines[28] = 'return total'
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_name(bufnr, directory .. '/project/source.lua')
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = 'lua'
local selected = vim.list_slice(lines, 24, 27)
local snapshot = {
  bufnr = bufnr, path = vim.api.nvim_buf_get_name(bufnr),
  root = directory .. '/project', filetype = 'lua', mode = 'V',
  start_line = 24, end_line = 27, lines = selected,
  text = table.concat(selected, '\n'),
}
local opts = require('opencode.config').merge(features).explanation
local prompt = assert(require('opencode.explanation.context').build(snapshot, opts))
assert(#prompt <= opts.context.max_bytes)
local payload = vim.json.decode(assert(prompt:match('Context %(JSON%):\n(.*)$')))
assert(payload.selection[1].line == 24 and payload.selection[4].line == 27)
for _, text in ipairs(selected) do assert(prompt:find(text, 1, true)) end
vim.fn.writefile({vim.json.encode({
  overlay = overlay, prompt = prompt, selected = selected,
  completion_model = completion_model, explanation_model = explanation_model,
})}, directory .. '/prepared.json')
""")
    return json.loads((profile / "prepared.json").read_text())


def run_client(repo, profile, env, port):
    run_nvim(repo, profile, dict(env, EXPLANATION_PORT=str(port)), r"""
vim.opt.runtimepath:append(vim.env.EXPLANATION_REPO)
local directory = vim.env.EXPLANATION_PROFILE
vim.cmd.cd(directory .. '/project')
local prepared = vim.json.decode(table.concat(vim.fn.readfile(directory .. '/prepared.json'), '\n'))
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.api.nvim_buf_set_lines(source, 0, -1, false, prepared.selected)
local before = vim.api.nvim_buf_get_lines(source, 0, -1, false)
local client = require('opencode.client')
client.setup({ host = '127.0.0.1', port = tonumber(vim.env.EXPLANATION_PORT),
  auth = { username = 'opencode', password = 'explanation-fixture-public-password' } })
client.connect_events()
assert(vim.wait(5000, function() return client.sse.is_connected() end, 10), 'SSE did not connect')
local done, err, answer, updates = false, nil, nil, {}
local handle = client.generate_explanation(prepared.prompt, prepared.explanation_model,
  function(request_error, text)
    err, answer, done = request_error, text, true
  end, { timeout = 10000, directory = directory .. '/project', on_update = function(text)
    assert(not done, 'Update arrived after completion')
    updates[#updates + 1] = text
  end })
assert(handle and type(handle.cancel) == 'function')
assert(vim.wait(15000, function() return done end, 10), 'Explanation HTTP request timed out')
assert(not err, vim.inspect(err))
assert(type(answer) == 'string' and answer:find('L24–27 —', 1, true) == 1)
assert(#updates >= 2 and updates[1] ~= answer and updates[#updates] == answer, 'Explanation was not streamed')
local cancelled
local cancel_handle = client.generate_explanation('CANCEL_FIXTURE', prepared.explanation_model,
  function(request_error) cancelled = request_error end,
  { timeout = 10000, directory = directory .. '/project', on_update = function() end })
assert(vim.wait(10000, function() return vim.fn.filereadable(directory .. '/cancel-ready') == 1 end, 10),
  'Cancellation fixture did not reach the model')
assert(cancel_handle.cancel())
assert(vim.wait(5000, function() return cancelled ~= nil end, 10), 'Cancellation callback did not arrive')
assert(cancelled.cancelled, vim.inspect(cancelled))
local state, settings = require('opencode.state'), require('opencode.settings')
local actions, model_profile = require('opencode.actions'), require('opencode.completion.profile')
local initial_model = { providerID = prepared.completion_model.providerID, modelID = prepared.completion_model.id }
local config = require('opencode.config').merge({
  settings = { file = directory .. '/settings.json' },
  completion = { enabled = true, model = initial_model, variant = 'low' },
  explanation = { enabled = true, model = initial_model, variant = 'low' },
})
state.set_config(settings.setup(config))
local function generate(feature, stage)
  local model = assert(model_profile.resolve(state.get_config()[feature], { managed = false }, feature))
  local finished, request_err, response
  client['generate_' .. feature]('SETTINGS_' .. feature .. '_' .. stage, model,
    function(error, text) request_err, response, finished = error, text, true end,
    { timeout = 10000, directory = directory .. '/project', on_update = function() end })
  assert(vim.wait(15000, function() return finished end, 10), 'Settings request timed out')
  assert(not request_err, vim.inspect(request_err))
  assert(type(response) == 'string' and response ~= '')
end
for _, feature in ipairs({ 'completion', 'explanation' }) do
  generate(feature, 'initial')
  assert(actions.apply_setting(feature .. '_model',
    { providerID = initial_model.providerID, modelID = 'fixture-alternate' }, 'global'))
  assert(actions.apply_setting(feature .. '_variant', 'none', 'cwd'))
  -- Reload persisted preferences before the next request, without restarting OpenCode.
  package.loaded['opencode.settings'] = nil
  settings = require('opencode.settings')
  state.set_config(settings.setup(config))
  generate(feature, 'none')
  assert(actions.apply_setting(feature .. '_variant', false, 'cwd'))
  generate(feature, 'default')
  assert(actions.apply_setting(feature .. '_variant', nil, 'cwd'))
  assert(actions.apply_setting(feature .. '_model', nil, 'global'))
  generate(feature, 'inherited')
end
local after = vim.api.nvim_buf_get_lines(source, 0, -1, false)
assert(vim.deep_equal(before, after), 'Source buffer changed')
client.disconnect_events()
vim.fn.writefile({vim.json.encode({ answer = answer, source_unchanged = true, streamed = true, cancelled = true,
  settings_changed = true })},
  directory .. '/client-result.json')
""")
    return json.loads((profile / "client-result.json").read_text())


def run(cli):
    repo = Path(__file__).resolve().parents[2]
    mock.ANSWER = ANSWER
    provider = mock.Provider()
    provider.answer_chunks = [ANSWER[:18], ANSWER[18:]]
    provider.chunk_delay = 0.1
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="opencode-nvim-explanation-") as temporary:
            profile = Path(temporary).resolve()
            env = {
                "PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
                "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
                "OPENCODE_SERVER_USERNAME": "opencode", "OPENCODE_SERVER_PASSWORD": PASSWORD,
                "OPENCODE_EXPLANATION_FIXTURE_KEY": "public-local-fixture-key",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            }
            env.update(profile_environment(profile))
            project = profile / "project"
            project.mkdir()
            config = {
                "model": f"{PROVIDER}/{MODEL}", "snapshots": False,
                "providers": {PROVIDER: {
                    "name": "Local explanation fixture", "env": ["OPENCODE_EXPLANATION_FIXTURE_KEY"],
                    "package": "@opencode/ai/providers/openai",
                    "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1",
                                 "apiKey": "public-local-fixture-key", "transport": "http"},
                    "models": {MODEL: {
                        "settings": {"reasoningEffort": "high"},
                        "body": {"max_output_tokens": 768},
                        "headers": {"X-Completion-Fixture": "ordinary"},
                        "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
                    }, "fixture-alternate": {
                        "settings": {"reasoningEffort": "high"},
                        "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
                        "variants": [{"id": "none", "settings": {"reasoningEffort": "none"}}],
                    }},
                }},
            }
            config_path = Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json"
            config_path.write_text(json.dumps(config))
            original_config = config_path.read_bytes()
            prepared = prepare(repo, profile, env)
            assert prepared["completion_model"]["variant"] != prepared["explanation_model"]["variant"]
            env["OPENCODE_CONFIG_CONTENT"] = prepared["overlay"]
            version = subprocess.run([cli, "--version"], env=env, cwd=project,
                                     check=True, capture_output=True, text=True, timeout=20).stdout.strip()
            authorization = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()
            process = None
            log_path = profile / "server.log"
            try:
                with log_path.open("w+") as log:
                    process = start_server(cli, env=env, cwd=project, log=log)
                    url = wait_server(process, log)

                    def request(method, path, body=None, allow_error=False):
                        req = urllib.request.Request(
                            url + path, method=method,
                            headers={"Authorization": authorization, "Content-Type": "application/json"},
                            data=None if body is None else json.dumps(body).encode(),
                        )
                        try:
                            response = urllib.request.urlopen(req, timeout=20)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            raw = response.read().decode()
                            data = json.loads(raw) if raw else None
                            assert allow_error or 200 <= response.status < 300, (response.status, data)
                            return response.status, data

                    location = "?location%5Bdirectory%5D=" + urllib.parse.quote(str(project), safe="")
                    _, before = request("GET", "/api/session" + location)
                    cold_started = time.monotonic()
                    while True:
                        status, reply = request("POST", "/api/experimental/generate", {
                            "prompt": "EXPLANATION_COLD_START", "model": prepared["explanation_model"]
                        }, allow_error=True)
                        if status == 200:
                            assert reply == {"data": {"text": ANSWER}}, reply
                            break
                        assert status == 400 and reply.get("_tag") == "InvalidRequestError", reply
                        assert reply.get("message") in [
                            f"Model unavailable: {PROVIDER}/{MODEL}",
                            f"Variant unavailable for {PROVIDER}/{MODEL}: "
                            + prepared["explanation_model"]["variant"],
                        ], reply
                        assert time.monotonic() - cold_started < 3, reply
                        time.sleep(0.05)
                    assert len(provider.requests) == 1, provider.requests
                    def signal_cancel_ready():
                        if provider.slow_started.wait(15):
                            (profile / "cancel-ready").touch()
                    threading.Thread(target=signal_cancel_ready, daemon=True).start()
                    client_result = run_client(repo, profile, env,
                                               int(url.rsplit(":", 1)[1]))
                    assert client_result == {"answer": ANSWER, "source_unchanged": True, "streamed": True,
                                             "cancelled": True, "settings_changed": True}
                    assert provider.slow_cancelled.wait(5), "Cancellation did not reach the model"
                    _, completion_reply = request("POST", "/api/experimental/generate", {
                        "prompt": "COMPLETION_PROFILE_CHECK", "model": prepared["completion_model"]
                    })
                    assert completion_reply == {"data": {"text": ANSWER}}, completion_reply
                    deadline = time.monotonic() + 5
                    while True:
                        _, after = request("GET", "/api/session" + location)
                        if before == after:
                            break
                        assert time.monotonic() < deadline, "Explanation left a temporary session behind"
                        time.sleep(0.05)
                    assert config_path.read_bytes() == original_config, "Config file was modified"
                    assert not (project / "source.lua").exists(), "Unsaved source leaked to disk"
                    assert len(provider.requests) == 12, provider.requests
                    explanation_request = provider.requests[1]
                    completion_request = provider.requests[-1]
                    assert not explanation_request["body"].get("tools"), explanation_request
                    assert "local total = 0" in json.dumps(explanation_request["body"]["input"])
                    assert explanation_request["body"]["reasoning"]["effort"] == "none"
                    assert explanation_request["body"]["max_output_tokens"] == 128
                    assert explanation_request["fixture_header"] == "explanation"
                    assert completion_request["body"]["reasoning"]["effort"] == "medium"
                    assert completion_request["body"]["max_output_tokens"] == 96
                    assert completion_request["fixture_header"] == "completion"
                    settings_requests = provider.requests[3:-1]
                    expected = [(MODEL, "low"), ("fixture-alternate", "none"),
                                ("fixture-alternate", "high"), (MODEL, "low")]
                    assert [(entry["body"]["model"], entry["body"]["reasoning"]["effort"])
                            for entry in settings_requests] == expected * 2
                    return {
                        "version": version,
                        "route": "/api/session/:sessionID/prompt + /api/event",
                        "streamed": True,
                        "provider_cancelled": True,
                        "answer": client_result["answer"],
                        "private_variants_distinct": True,
                        "explanation_reasoning_effort": "none",
                        "completion_reasoning_effort": "medium",
                        "saved_settings_apply_without_restart": True,
                        "settings_provider_payloads": [
                            {"model": entry["body"]["model"], "reasoning_effort": entry["body"]["reasoning"]["effort"]}
                            for entry in settings_requests
                        ],
                        "provider_tools_absent": True,
                        "sessions_unchanged": True,
                        "source_buffer_unchanged": True,
                        "unsaved_source_not_written": True,
                        "real_provider_requests": 0,
                    }
            finally:
                stop_server(process)
    finally:
        provider.shutdown()
        provider.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=shutil.which("opencode"), help="OpenCode 2.0.11+ executable")
    args = parser.parse_args()
    assert args.cli, "OpenCode executable not found"
    print(json.dumps(run(str(Path(args.cli).resolve())), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
