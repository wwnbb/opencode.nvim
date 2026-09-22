"""Real v2 integration/credential semantics, using public sentinels only."""
import time
from urllib.parse import quote


def run(request, save, location):
    base = "/api/integration/groq"
    def get():
        status, result = request("GET", base + location)
        assert status == 200, result
        return result
    integration = get()
    save("integration-methods.json", integration)
    assert any(m.get("id") == "test-code" for m in integration["data"]["methods"]), integration
    assert any(c["type"] == "env" for c in integration["data"]["connections"]), integration
    status, error = request("POST", base + "/connect/key" + location, {"key": "public-key-sentinel"})
    save("integration-key-invalid.json", {"status": status, "response": error})
    assert status >= 400, error
    for label in ["account-one", "account-two"]:
        status, result = request("POST", base + "/connect/key" + location,
                                 {"key": "public-key-" + label, "answer": {"region": "test"}, "label": label})
        assert status == 204, result
    connected = get()
    save("integration-connected.json", connected)
    credentials = [c for c in connected["data"]["connections"] if c["type"] == "credential"]
    assert len(credentials) == 2, credentials
    selected = next(c for c in credentials if c["label"] == "account-one")
    path = "/api/credential/" + quote(selected["id"], safe="")
    assert request("PATCH", path, {"label": "renamed-one"})[0] == 204
    assert request("POST", path + "/activate", {})[0] == 204
    assert request("DELETE", path)[0] == 204
    remaining = get()
    save("integration-disconnected.json", remaining)
    assert any(c.get("label") == "account-two" for c in remaining["data"]["connections"])
    assert any(c["type"] == "env" for c in remaining["data"]["connections"])
    assert not any(c.get("id") == selected["id"] for c in remaining["data"]["connections"])
    code, result = request("POST", path + "/activate", {})
    save("credential-missing-activate.json", {"status": code, "response": result})
    # 2.0.11 acknowledges activation of an absent credential as an idempotent no-op.
    assert code == 204
    assert not any(c.get("id") == selected["id"] for c in get()["data"]["connections"])

    def start(kind, method):
        code, result = request("POST", base + "/connect/" + kind + location, {"methodID": method})
        save(method + "-start.json", {"status": code, "response": result})
        assert code == 200, result
        return base + "/connect/" + kind + "/" + quote(result["data"]["attemptID"], safe="")
    def wait(path):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            code, result = request("GET", path + location)
            assert code == 200, result
            if result["data"]["status"] != "pending": return result
            time.sleep(0.05)
        raise AssertionError("Auth attempt did not terminate")
    for kind, method in [("oauth", "test-code"), ("oauth", "test-auto"), ("oauth", "test-expired"), ("command", "test-command")]:
        path = start(kind, method)
        if method == "test-code":
            assert request("POST", path + "/complete" + location, {"code": "public-test-code"})[0] == 204
        if method == "test-expired":
            time.sleep(0.2)
            code, result = request("GET", path + location)
            assert code == 200
            # 2.0.11 can still report pending past expires; the frontend must bound polling.
            assert result["data"]["time"]["expires"] < time.time() * 1000
            assert result["data"]["status"] in ["pending", "expired"]
            assert request("DELETE", path + location)[0] == 204
        else:
            result = wait(path)
            assert result["data"]["status"] == "complete", result
        save(method + "-status.json", result)
    for kind, method in [("oauth", "test-cancel"), ("command", "test-command-cancel")]:
        path = start(kind, method)
        assert request("DELETE", path + location)[0] == 204
        code, result = request("GET", path + location)
        save(method + "-status.json", {"status": code, "response": result})
        assert code == 404 or result["data"]["status"] in ["failed", "expired"], result
    code, result = request("POST", base + "/connect/oauth" + location, {"methodID": "missing-method"})
    save("integration-missing-method.json", {"status": code, "response": result})
    assert code >= 400, result
