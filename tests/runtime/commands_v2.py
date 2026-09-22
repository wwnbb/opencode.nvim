"""Native command admission is 204; execution is observed in history."""
import time


def run(request, save, prefix, location):
    code, catalog = request("GET", "/api/command" + location)
    assert code == 200 and any(item["name"] == "v2-native-smoke" for item in catalog["data"]), catalog
    code, admission = request("POST", prefix + "/command", {"name": "v2-native-smoke", "text": "", "delivery": "queue"})
    save("command-admission.json", {"status": code, "response": admission})
    assert code == 204, admission
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        code, history = request("GET", prefix + "/message")
        assert code == 200, history
        if any(m["type"] == "idle" for m in history["data"]):
            break
        time.sleep(0.25)
    else:
        raise AssertionError("Native command timeout")
    save("command-history.json", history)
    assert sum(m["type"] == "user" for m in history["data"]) == 1, history
    assert any(c.get("type") == "text" and "COMMAND_V2_READY" in c.get("text", "")
               for m in history["data"] for c in m.get("content", [])), history
