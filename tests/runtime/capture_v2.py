#!/usr/bin/env python3
"""Capture real OpenCode 2.0.11+ HTTP/SSE in a disposable, credential-free profile.

Pass --model provider/id to perform a real model request. No personal config or
credentials are inherited. The output directory is an explicit, new directory.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", help="Explicit provider/id; may incur provider charges")
    parser.add_argument("--provider-key-env", help="Explicitly forward this one credential environment variable to the selected provider")
    parser.add_argument("--nvim-smoke", action="store_true", help="Also run the Neovim frontend smoke with the selected model")
    parser.add_argument("--interactions", action="store_true")
    parser.add_argument("--nvim-interactions", action="store_true")
    parser.add_argument("--nvim-form-ui", action="store_true")
    parser.add_argument("--nvim-form-history", action="store_true")
    parser.add_argument("--nvim-subagents", action="store_true")
    parser.add_argument("--nvim-stream-layout", action="store_true")
    parser.add_argument("--nvim-input-attachments", action="store_true")
    parser.add_argument("--server-plugin", help="Explicit path to the bundled server plugin under test")
    parser.add_argument("--nvim-review", action="store_true")
    parser.add_argument("--nvim-review-matrix", action="store_true")
    parser.add_argument("--nvim-server-review", action="store_true")
    parser.add_argument("--nvim-rg", action="store_true")
    parser.add_argument("--nvim-queue", action="store_true")
    parser.add_argument("--nvim-selection", action="store_true")
    parser.add_argument("--nvim-auth-ui", action="store_true")
    parser.add_argument("--nvim-mcp-auth-ui", action="store_true")
    parser.add_argument("--nvim-compatibility", choices=["missing", "obsolete"])
    parser.add_argument("--nvim-session-scope", action="store_true")
    parser.add_argument("--nvim-ui", action="store_true")
    parser.add_argument("--nvim-lifecycle", action="store_true")
    parser.add_argument("--nvim-reconnect", action="store_true")
    parser.add_argument("--attached-ui", action="store_true", help="Capture native Neovim line grids; requires Python msgpack and Pillow")
    parser.add_argument("--mcp", action="store_true")
    parser.add_argument("--session-ops", action="store_true")
    parser.add_argument("--subagents", action="store_true")
    parser.add_argument("--attachments", action="store_true")
    parser.add_argument("--commands", action="store_true")
    parser.add_argument("--auth", action="store_true", help="Test public fake integration methods in the isolated profile")
    parser.add_argument("--install-tools", action="store_true", help="Install the plugin into this clean test profile using the real installer")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    cli = str(Path(args.cli).resolve())
    profile = Path(tempfile.mkdtemp(prefix="opencode-nvim-v2-")).resolve()
    env = {"PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1"}
    for key, directory in {
        "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data",
        "XDG_STATE_HOME": "state", "XDG_CACHE_HOME": "cache",
        "TMPDIR": "tmp", "OPENCODE_CONFIG_DIR": "config/opencode",
        "OPENCODE_TEST_HOME": "home",
    }.items():
        path = profile / directory
        path.mkdir(parents=True, exist_ok=True)
        env[key] = str(path)
    # Public test credential, used only for this disposable loopback server.
    env["OPENCODE_SERVER_USERNAME"] = "opencode"
    env["OPENCODE_SERVER_PASSWORD"] = "opencode-nvim-test-only"
    authorization = "Basic " + base64.b64encode(b"opencode:opencode-nvim-test-only").decode()
    project = profile / ("project-session-ops" if args.session_ops else "project пробел %#")
    project.mkdir()
    subprocess.run(["git", "init", "--quiet", str(project)], env=env, check=True)
    if args.session_ops:
        (project / "counter.txt").write_text("one\n")
        subprocess.run(["git", "add", "counter.txt"], cwd=project, env=env, check=True)
        subprocess.run(["git", "-c", "user.name=OpenCode Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "Test fixture"], cwd=project, env=env, check=True)
    if args.install_tools:
        repo = Path(__file__).resolve().parents[2]
        subprocess.run([str(repo / "scripts/install-tools.sh"), env["OPENCODE_CONFIG_DIR"]], check=True,
                       env=dict(env, NPM_CONFIG_CACHE=str(profile / "cache/npm")))
        args.server_plugin = str(Path(env["OPENCODE_CONFIG_DIR"]) / "plugins/opencode-nvim")
    elif args.server_plugin:
        plugin_path = str(Path(args.server_plugin).resolve())
        (Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json").write_text(json.dumps({"plugins": [plugin_path]}))
    secret = None
    if args.provider_key_env:
        assert args.model and not args.install_tools, "An explicit model and JSON test configuration are required"
        secret = os.environ[args.provider_key_env]
        assert secret, "Empty provider credential"
        env["OPENCODE_NVIM_RUNTIME_PROVIDER_KEY"] = secret
        config_path = Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json"
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        provider_id = args.model.split("/", 1)[0]
        config.setdefault("providers", {})[provider_id] = {"env": ["OPENCODE_NVIM_RUNTIME_PROVIDER_KEY"]}
        config_path.write_text(json.dumps(config))
    if args.auth or args.nvim_auth_ui:
        # Resolve pinned plugin dependencies without installing or reading personal config.
        import shutil
        repo = Path(__file__).resolve().parents[2]
        fixture = profile / "auth-fixture"
        fixture.mkdir()
        shutil.copyfile(Path(__file__).with_name("auth_fixture.ts"), fixture / "index.ts")
        (fixture / "node_modules").symlink_to(repo / "opencode_nvim/plugins/opencode-nvim/node_modules", target_is_directory=True)
        config_path = Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json"
        assert not args.install_tools, "Run auth fixture independently of JSONC installer test"
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        config.setdefault("plugins", []).append(str(fixture))
        config_path.write_text(json.dumps(config))
        env["OPENCODE_NVIM_TEST_INTEGRATION_ENV"] = "public-env-test-key"
    if args.nvim_compatibility:
        assert not args.server_plugin and not args.install_tools, "Compatibility scenario controls its own plugin setup"
        env["OPENCODE_V2_COMPATIBILITY"] = args.nvim_compatibility
        if args.nvim_compatibility == "obsolete":
            import shutil
            repo = Path(__file__).resolve().parents[2]
            fixture = profile / "obsolete-plugin-fixture"
            fixture.mkdir()
            shutil.copyfile(Path(__file__).with_name("obsolete_plugin_fixture.ts"), fixture / "index.ts")
            (fixture / "node_modules").symlink_to(repo / "opencode_nvim/plugins/opencode-nvim/node_modules", target_is_directory=True)
            (Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json").write_text(json.dumps({"plugins": [str(fixture)]}))
    if args.nvim_ui:
        skill = Path(env["OPENCODE_CONFIG_DIR"]) / "skills/smoke-native"
        skill.mkdir(parents=True, exist_ok=True)
        (skill / "SKILL.md").write_text("---\nname: smoke-native\ndescription: Isolated frontend test skill\n---\nWhen this skill is activated, reply exactly SKILL_V2_READY. Do not call tools.\n")
    if args.commands:
        command = Path(env["OPENCODE_CONFIG_DIR"]) / "commands/v2-native-smoke.md"
        command.parent.mkdir(parents=True, exist_ok=True)
        command.write_text("---\ndescription: Native command fixture\n---\nReply exactly COMMAND_V2_READY. Do not call tools.\n")
    if args.nvim_input_attachments:
        import sys
        from attachments_v2 import red_png
        # Exercise the macOS image reader without touching the user's clipboard.
        shim = profile / "clipboard-source"
        shim.mkdir()
        (shim / "source.png").write_bytes(red_png())
        executable = shim / "osascript"
        executable.write_text("#!" + sys.executable + "\nimport pathlib,re,sys\n"
            "target=re.search(r'POSIX file \"([^\"]+)\"', ' '.join(sys.argv))\n"
            "assert target, 'Unexpected clipboard command'\n"
            "pathlib.Path(target[1]).write_bytes(pathlib.Path(__file__).with_name('source.png').read_bytes())\n"
            "pathlib.Path(__file__).with_name('called').write_text('PNGf')\n")
        executable.chmod(0o755)
        env["PATH"] = str(shim) + os.pathsep + env["PATH"]
        env["OPENCODE_V2_CLIPBOARD_SOURCE"] = str(shim)
    events = []
    exchanges = []

    def save(name, data):
        text = data if isinstance(data, str) else json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        if secret:
            text = text.replace(secret, "<REDACTED_PROVIDER_KEY>")
        (output / name).write_text(text.replace(str(profile), "<PROFILE>"))

    runtime_version = None
    for name, command in [("version", ["--version"]), ("serve-help", ["serve", "--help"]), ("paths", ["debug", "paths"])]:
        result = subprocess.run([cli, *command], env=env, cwd=project, capture_output=True, text=True, timeout=30, check=True)
        save(name + ".txt", result.stdout)
        if name == "version":
            match = re.fullmatch(r"opencode v(2)\.(\d+)\.(\d+)", result.stdout.strip())
            assert match and (int(match[2]), int(match[3])) >= (0, 11), result.stdout
            runtime_version = ".".join(match.groups())
        if name == "paths":
            for line in result.stdout.splitlines():
                assert str(profile) in line, "Non-isolated runtime path: " + line

    with (output / "serve.txt").open("w+") as server_log:
        process = subprocess.Popen([cli, "serve", "--hostname", "127.0.0.1", "--port", "0"],
                                   env=env, cwd=project, stdout=server_log, stderr=subprocess.STDOUT)
        stream = None
        try:
            deadline = time.monotonic() + 30
            url = None
            while time.monotonic() < deadline:
                server_log.seek(0)
                match = re.search(r"server listening on (http://127\.0\.0\.1:\d+)", server_log.read())
                if match:
                    url = match.group(1)
                    break
                assert process.poll() is None, "Server exited before readiness"
                time.sleep(0.1)
            assert url, "No listening URL before deadline"

            def request(method, path, body=None, authenticated=True):
                headers = {"Accept": "application/json"}
                if authenticated:
                    headers["Authorization"] = authorization
                if body is not None:
                    headers["Content-Type"] = "application/json"
                req = urllib.request.Request(url + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
                try:
                    response = urllib.request.urlopen(req, timeout=30)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    raw = response.read().decode()
                    data = json.loads(raw) if raw else None
                    exchanges.append({"method": method, "path": path, "request": body, "status": response.status, "response": data})
                    return response.status, data

            code, info = request("GET", "/api/info")
            assert code == 200 and info["version"] == runtime_version and info["pid"] == process.pid
            save("info.json", info)
            code, _ = request("GET", "/api/info", authenticated=False)
            assert code == 401, "Configured Basic auth is not enforced"
            stream = urllib.request.urlopen(urllib.request.Request(url + "/api/event", headers={"Authorization": authorization, "Accept": "text/event-stream"}), timeout=120)

            def read_events():
                data = []
                try:
                    for raw in stream:
                        line = raw.decode().rstrip("\r\n")
                        if line.startswith("data:"):
                            data.append(line[5:].lstrip())
                        elif not line and data:
                            events.append(json.loads("\n".join(data)))
                            data = []
                except (OSError, ValueError):
                    pass

            reader = threading.Thread(target=read_events, daemon=True)
            reader.start()
            location = "?" + urllib.parse.urlencode({"location[directory]": str(project)})
            for endpoint in ["agent", "model", "model/default", "provider", "plugin"]:
                deadline = time.monotonic() + 30
                while True:
                    code, data = request("GET", "/api/" + endpoint + location)
                    assert code == 200, data
                    if endpoint not in ["agent", "model"] or data.get("data") or time.monotonic() > deadline:
                        break
                    time.sleep(0.2)
                save(endpoint.replace("/", "-") + ".json", data)
            if args.auth:
                from auth_v2 import run as run_auth
                run_auth(request, save, location)
            if args.mcp:
                from mcp_v2 import run as run_mcp
                run_mcp(request, save, location)
            if args.server_plugin:
                code, capability = request("POST", "/api/rpc/opencode_nvim/capabilities" + location, {"input": {}})
                save("capabilities.json", {"status": code, "response": capability})
                assert code == 200 and capability["output"]["protocolVersion"] == 2, capability
            for enabled, script, name in [(args.nvim_smoke, "v2_smoke.lua", "nvim"),
                                          (args.nvim_interactions, "v2_interactions.lua", "nvim-interactions"),
                                          (args.nvim_form_ui, "v2_form_ui.lua", "nvim-form-ui"),
                                          (args.nvim_form_history, "v2_form_history.lua", "nvim-form-history"),
                                          (args.nvim_subagents, "v2_subagents.lua", "nvim-subagents"),
                                          (args.nvim_stream_layout, "v2_stream_layout.lua", "nvim-stream-layout"),
                                          (args.nvim_input_attachments, "v2_input_attachments.lua", "nvim-input-attachments"),
                                          (args.auth, "v2_auth.lua", "nvim-auth"),
                                          (args.nvim_auth_ui, "v2_auth_ui.lua", "nvim-auth-ui"),
                                          (args.nvim_mcp_auth_ui, "v2_mcp_auth_ui.lua", "nvim-mcp-auth-ui"),
                                          (args.nvim_compatibility, "v2_compatibility.lua", "nvim-compatibility"),
                                          (args.nvim_review, "v2_review.lua", "nvim-review"),
                                          (args.nvim_review_matrix, "v2_review_matrix.lua", "nvim-review-matrix"),
                                          (args.nvim_server_review, "v2_server_review.lua", "nvim-server-review"),
                                          (args.nvim_rg, "v2_rg.lua", "nvim-rg"),
                                          (args.nvim_queue, "v2_queue.lua", "nvim-queue"),
                                          (args.nvim_selection, "v2_selection.lua", "nvim-selection"),
                                          (args.nvim_session_scope, "v2_session_scope.lua", "nvim-session-scope"),
                                          (args.nvim_ui, "v2_ui.lua", "nvim-ui"),
                                          (args.nvim_lifecycle, "v2_lifecycle.lua", "nvim-lifecycle"),
                                          (args.nvim_reconnect, "v2_reconnect.lua", "nvim-reconnect")]:
                if not enabled:
                    continue
                if script in ["v2_smoke.lua", "v2_input_attachments.lua", "v2_review.lua", "v2_review_matrix.lua", "v2_server_review.lua", "v2_rg.lua", "v2_queue.lua", "v2_selection.lua", "v2_session_scope.lua", "v2_ui.lua", "v2_reconnect.lua"]:
                    assert args.model, "--nvim-smoke requires an explicitly selected --model"
                repo = Path(__file__).resolve().parents[2]
                nvim_env = dict(env, OPENCODE_V2_SERVER_URL=url, OPENCODE_V2_PROJECT=str(project), OPENCODE_V2_CLI=cli,
                                OPENCODE_V2_MODEL=args.model or "", OPENCODE_V2_OUTPUT=str(output / (name + ".json")),
                                NVIM_LOG_FILE=str(profile / "nvim.log"))
                if args.attached_ui:
                    from native_ui import run as run_ui
                    result = run_ui(repo, script, nvim_env, output)
                else:
                    result = subprocess.run(["nvim", "--headless", "--noplugin", "-n", "-i", "NONE",
                                             "-u", str(repo / "tests/minimal_init.lua"),
                                             "-l", str(repo / "tests/runtime" / script)],
                                            env=nvim_env, cwd=repo, capture_output=True, text=True, timeout=330)
                save(name + "-output.txt", result.stdout + result.stderr)
                assert result.returncode == 0, f"Neovim exited {result.returncode}:\n" + result.stdout + result.stderr
                save(name + ".json", json.loads((output / (name + ".json")).read_text()))
            body = {"title": "opencode.nvim v2 runtime fixture", "location": {"directory": str(project)}}
            if args.model:
                provider, model = args.model.split("/", 1)
                body["model"] = {"providerID": provider, "id": model}
            code, created = request("POST", "/api/session", body)
            assert code == 200, created
            session_id = created["data"]["id"]
            save("session.json", created)
            code, listing = request("GET", "/api/session?limit=1&parentID=null")
            assert code == 200 and listing["data"][0]["id"] == session_id
            save("sessions.json", listing)
            prefix = "/api/session/" + session_id
            if args.interactions:
                from interactions_v2 import capture
                capture(request, prefix, save)
            if args.session_ops:
                assert args.model, "Session operations require the explicit test model"
                from session_ops_v2 import run as run_session_ops
                run_session_ops(request, save, prefix, project, env)
            if args.subagents:
                assert args.model, "Subagent test requires an explicit model"
                from subagents_v2 import run as run_subagents
                run_subagents(request, save, prefix)
            if args.attachments:
                assert args.model, "Attachments require the explicit test model"
                from attachments_v2 import run as run_attachments
                run_attachments(request, save, prefix, project)
            if args.commands:
                assert args.model, "Commands require the explicit test model"
                from commands_v2 import run as run_commands
                run_commands(request, save, prefix, location)
            if args.model and not args.session_ops and not args.subagents and not args.attachments and not args.commands and not args.nvim_input_attachments and not args.nvim_queue and not args.nvim_selection and not args.nvim_form_history and not args.nvim_subagents and not args.nvim_stream_layout:
                prompt = {"id": "msg_nvim_v2_fixture", "text": "Reply with exactly: Привет, Neovim!", "delivery": "queue"}
                code, accepted = request("POST", prefix + "/prompt", prompt)
                assert code == 200, accepted
                save("prompt.json", accepted)
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    code, history = request("GET", prefix + "/message")
                    assert code == 200, history
                    if any(m.get("type") == "idle" for m in history["data"]):
                        break
                    time.sleep(0.5)
                else:
                    raise AssertionError("No idle message before deadline")
                save("history.json", history)
                code, duplicate = request("POST", prefix + "/prompt", prompt)
                save("duplicate-prompt.json", {"status": code, "response": duplicate})
            else:
                code, history = request("GET", prefix + "/message")
                assert code == 200
                save("history.json", history)
            code, _ = request("DELETE", prefix)
            assert code == 204
            code, _ = request("GET", prefix)
            assert code == 404
            print("Captured runtime fixtures:", output)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if stream:
                stream.close()
            save("events.json", events)
            save("http.json", exchanges)
            save("exit.json", {"code": process.returncode, "observed": process.poll() is not None})
            if secret:
                for target in output.iterdir():
                    if target.suffix in {".txt", ".json"}:
                        target.write_text(target.read_text().replace(secret, "<REDACTED_PROVIDER_KEY>"))
            print("Isolated profile retained for diagnostics:", profile)


if __name__ == "__main__":
    main()
