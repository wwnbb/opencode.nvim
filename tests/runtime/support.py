"""Small stdlib helpers for disposable native runtime fixtures."""
import re
import subprocess
import time


PROFILE_PATHS = {
    "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_STATE_HOME": "state",
    "XDG_CACHE_HOME": "cache", "TMPDIR": "tmp", "OPENCODE_CONFIG_DIR": "config/opencode",
    "OPENCODE_TEST_HOME": "home",
}


def profile_environment(profile, *, create=True):
    result = {}
    for name, relative in PROFILE_PATHS.items():
        path = profile / relative
        if create:
            path.mkdir(parents=True, exist_ok=True)
        else:
            assert path.is_dir(), f"Not a complete capture profile: {path}"
        result[name] = str(path)
    return result


def start_server(cli, *, env, cwd, log):
    # Callers supply their explicit allowlist; never inherit the user environment.
    return subprocess.Popen([cli, "serve", "--hostname", "127.0.0.1", "--port", "0"],
                            env=env, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)


def wait_server(process, log, *, interval=0.05):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        log.seek(0)
        content = log.read()
        match = re.search(r"server listening on (http://127\.0\.0\.1:\d+)", content)
        if match:
            return match[1]
        assert process.poll() is None, "Server exited before readiness: " + content
        time.sleep(interval)
    raise AssertionError("No listening URL before deadline: " + content)


def stop_server(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
