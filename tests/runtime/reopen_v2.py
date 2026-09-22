#!/usr/bin/env python3
"""Reopen a retained capture_v2.py profile without issuing any model prompt.

Only task-created disposable profiles are accepted. Scenarios may mutate/delete
their test sessions; native snapshots are saved before those operations.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import base64
import urllib.request

from native_ui import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--scenario", choices=["navigation", "background", "review", "form"], required=True)
    parser.add_argument("--restore-subagent-fixture", help="Restore recorded native sessions via the public experimental import endpoint")
    args = parser.parse_args()
    profile = Path(args.profile).resolve()
    assert profile.name.startswith("opencode-nvim-v2-") and str(profile).startswith(("/private/tmp/", "/private/var/folders/"))
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    projects = list(profile.glob("project*"))
    assert len(projects) == 1 and projects[0].is_dir()
    project = projects[0]
    env = {"PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1"}
    for name, relative in {"XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_STATE_HOME": "state",
                           "XDG_CACHE_HOME": "cache", "TMPDIR": "tmp", "OPENCODE_CONFIG_DIR": "config/opencode",
                           "OPENCODE_TEST_HOME": "home"}.items():
        target = profile / relative
        assert target.is_dir(), f"Not a complete capture profile: {target}"
        env[name] = str(target)
    env.update(OPENCODE_SERVER_USERNAME="opencode", OPENCODE_SERVER_PASSWORD="opencode-nvim-test-only")
    cli = str(Path(args.cli).resolve())
    version = subprocess.run([cli, "--version"], env=env, cwd=project, capture_output=True, text=True, check=True, timeout=30)
    assert version.stdout.strip() == "opencode v2.0.11"
    paths = subprocess.run([cli, "debug", "paths"], env=env, cwd=project, capture_output=True, text=True, check=True, timeout=30)
    assert all(str(profile) in line for line in paths.stdout.splitlines())
    repo = Path(__file__).resolve().parents[2]
    with (output / "serve.txt").open("w+") as log:
        process = subprocess.Popen([cli, "serve", "--hostname", "127.0.0.1", "--port", "0"], env=env, cwd=project, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline, url = time.monotonic() + 30, None
            while time.monotonic() < deadline:
                log.seek(0)
                match = re.search(r"server listening on (http://127\.0\.0\.1:\d+)", log.read())
                if match:
                    url = match.group(1)
                    break
                assert process.poll() is None, "Server exited before readiness"
                time.sleep(0.1)
            assert url, "Server did not start"
            if args.restore_subagent_fixture:
                assert args.scenario == "navigation"
                source = Path(args.restore_subagent_fixture).resolve()
                def read(name):
                    return json.loads((source / name).read_text().replace("<PROFILE>", str(profile)))
                parent = read("session.json")["data"]
                assert parent["id"] == args.session
                records = [(parent, read("subagent-parent.json")["data"])]
                for target in sorted(source.glob("subagent-child-*.json")):
                    child = read(target.name)
                    records.append((child["session"], child["history"]["data"]))
                for info, messages in records:
                    req = urllib.request.Request(url + "/api/experimental/session/import", method="POST",
                        headers={"Authorization": "Basic " + base64.b64encode(b"opencode:opencode-nvim-test-only").decode(), "Content-Type": "application/json"},
                        data=json.dumps({"info": info, "messages": messages, "location": {"directory": str(project)}}).encode())
                    with urllib.request.urlopen(req, timeout=30) as response:
                        assert response.status == 200
            env.update(OPENCODE_V2_SERVER_URL=url, OPENCODE_V2_PROJECT=str(project), OPENCODE_V2_SESSION=args.session,
                       OPENCODE_V2_SCENARIO=args.scenario, OPENCODE_V2_OUTPUT=str(output / "reopened.json"), NVIM_LOG_FILE=str(profile / "nvim-reopen.log"))
            result = run(repo, "v2_reopen.lua", env, output)
            assert result.returncode == 0, result.stderr
            (output / "nvim-output.txt").write_text(result.stdout + result.stderr)
            (output / "provenance.json").write_text(json.dumps({"version": "2.0.11", "scenario": args.scenario, "session": args.session,
                                                              "new_model_requests": 0, "reopened_disposable_profile": True,
                                                              "restored_native_subagent_fixtures": bool(args.restore_subagent_fixture)}, indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            for target in output.iterdir():
                if target.suffix in {".txt", ".json"}:
                    target.write_text(target.read_text().replace(str(profile), "<PROFILE>"))
    print(f"Reopened runtime fixtures: {output}")


if __name__ == "__main__":
    main()
