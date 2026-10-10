"""Run with python3 tests/runtime/support_test.py; no server or model required."""
import os
from pathlib import Path
import tempfile
from unittest.mock import Mock, patch

from support import PROFILE_PATHS, profile_environment, start_server, wait_server, stop_server


with tempfile.TemporaryDirectory(prefix="opencode-runtime-support-") as temporary:
    profile = Path(temporary)
    env = profile_environment(profile)
    assert set(env) == set(PROFILE_PATHS)
    assert all(Path(value).is_dir() and Path(value).is_relative_to(profile) for value in env.values())
    assert profile_environment(profile, create=False) == env
    (profile / "home").rmdir()
    try:
        profile_environment(profile, create=False)
    except AssertionError as error:
        assert "Not a complete capture profile" in str(error)
    else:
        raise AssertionError("Incomplete retained profile was accepted")

    log = Mock()
    allowed = {"PATH": "/explicit-bin", **env}
    with patch.dict(os.environ, {"PERSONAL_SECRET": "must-not-be-inherited"}), patch("support.subprocess.Popen") as spawn:
        start_server("/fixture-cli", env=allowed, cwd=profile, log=log)
        assert spawn.call_args.args[0] == ["/fixture-cli", "serve", "--hostname", "127.0.0.1", "--port", "0"]
        assert spawn.call_args.kwargs["env"] is allowed
        assert "PERSONAL_SECRET" not in spawn.call_args.kwargs["env"]
        assert spawn.call_args.kwargs["cwd"] == profile

    process = Mock()
    log.read.return_value = "server listening on http://127.0.0.1:12345\n"
    assert wait_server(process, log) == "http://127.0.0.1:12345"
    log.read.return_value = "fixture exited"
    process.poll.return_value = 1
    try:
        wait_server(process, log)
    except AssertionError as error:
        assert "fixture exited" in str(error)
    else:
        raise AssertionError("Exited server was treated as ready")
    process.poll.return_value = None
    from subprocess import TimeoutExpired
    process.wait.side_effect = [TimeoutExpired("fixture", 10), 0]
    stop_server(process)
    process.terminate.assert_called_once()
    process.kill.assert_called_once()
    assert [call.kwargs["timeout"] for call in process.wait.call_args_list] == [10, 5]
    stop_server(None)

print("Runtime profile isolation, explicit environment, readiness and teardown passed")
