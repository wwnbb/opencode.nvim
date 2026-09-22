"""Real turn boundaries and disk semantics for fork / diff / revert / compact."""
import time
from urllib.parse import urlencode


def run(request, save, prefix, project, env):
    file = project / "counter.txt"
    def history(route=prefix):
        code, data = request("GET", route + "/message")
        assert code == 200, data
        return data
    def wait(new_id, route=prefix, old_idle=0):
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            data = history(route)
            idle = [m for m in data["data"] if m["type"] == "idle"]
            if len(idle) > old_idle:
                assert idle[0]["outcome"] == "succeeded", data
                return data
            time.sleep(0.25)
        raise AssertionError("Session operation did not finish: " + new_id)
    user_ids = []
    for previous, value in [("one", "two"), ("two", "three")]:
        before = history()
        idle_count = sum(m["type"] == "idle" for m in before["data"])
        code, admission = request("POST", prefix + "/prompt", {"text": f"Use your file editing tool to replace {previous} with {value} in counter.txt. Pass the relative path counter.txt exactly. Preserve the final newline. Do not change any other file. Then reply Done.", "delivery": "queue"})
        assert code == 200, admission
        user_ids.append(admission["data"]["id"])
        data = wait(user_ids[-1], old_idle=idle_count)
        save("turn-" + value + ".json", data)
        assert file.read_text() == value + "\n", data
    code, diff = request("GET", prefix + "/diff?" + urlencode({"from": user_ids[0], "to": user_ids[1]}))
    save("session-diff.json", {"status": code, "response": diff})
    assert code == 200 and diff["data"], diff
    code, fork = request("POST", prefix + "/fork", {"before": user_ids[1]})
    assert code == 200, fork
    fork_prefix = "/api/session/" + fork["data"]["id"]
    fork_history = history(fork_prefix)
    save("session-fork.json", {"session": fork, "history": fork_history})
    assert any(m["type"] == "user" for m in fork_history["data"]), fork_history
    assert not any(m["id"] == user_ids[1] for m in fork_history["data"]), fork_history
    before_history = history()
    code, staged = request("POST", prefix + "/revert/stage", {"messageID": user_ids[1], "files": True})
    stage_history = history()
    save("revert-staged.json", {"status": code, "response": staged, "file": file.read_text(), "history": stage_history})
    assert code == 200, staged
    assert file.read_text() == "two\n"
    assert any(m["id"] == user_ids[1] for m in stage_history["data"])
    assert request("DELETE", prefix + "/revert")[0] == 204
    save("revert-cleared.json", {"file": file.read_text(), "history": history()})
    assert file.read_text() == "three\n"
    assert request("POST", prefix + "/revert/stage", {"messageID": user_ids[1], "files": True})[0] == 200
    assert request("POST", prefix + "/revert/commit", {})[0] == 204
    committed = history()
    save("revert-committed.json", {"file": file.read_text(), "history": committed})
    assert file.read_text() == "two\n"
    assert not any(m["id"] >= user_ids[1] for m in committed["data"])
    idle_count = sum(m["type"] == "idle" for m in committed["data"])
    code, compact = request("POST", prefix + "/compact", {"delivery": "queue"})
    save("session-compact.json", {"status": code, "response": compact})
    assert code == 200 and compact["data"]["type"] == "compaction", compact
    compacted = wait(compact["data"]["id"], old_idle=idle_count)
    save("session-compacted-history.json", compacted)
    assert any(m["type"] == "compaction" and m.get("status") == "completed" for m in compacted["data"]), compacted
    assert request("DELETE", fork_prefix)[0] == 204
    for operation, body in [("fork", {"before": "missing"}), ("revert/stage", {"messageID": "missing"}), ("compact", {"delivery": "invalid"})]:
        code, error = request("POST", prefix + "/" + operation, body)
        save(operation.replace("/", "-") + "-invalid.json", {"status": code, "response": error})
        assert code >= 400, (operation, code, error)
