"""Real session-scoped interaction contract probes; no model execution."""

def capture(request, prefix, save):
    fields = [
        {"key": "target", "type": "string", "required": True, "options": [
            {"label": "Same", "value": "a"}, {"label": "Same", "value": "b"}]},
        {"key": "checks", "type": "multiselect", "minItems": 1, "maxItems": 2, "options": [
            {"label": "Unit", "value": "unit"}, {"label": "Integration", "value": "integration"}]},
        {"key": "retries", "type": "integer", "minimum": 0, "maximum": 3, "default": 0},
        {"key": "ratio", "type": "number", "minimum": 0, "maximum": 1},
        {"key": "confirm", "type": "boolean", "required": True, "default": False},
        {"key": "note", "type": "string", "required": True, "when": [{"key": "confirm", "op": "eq", "value": True}]},
        {"key": "hidden", "type": "string", "hidden": True, "required": True, "default": "secret-default"},
    ]
    code, form = request("POST", prefix + "/form", {"title": "Typed form fixture", "fields": fields})
    assert code == 200, form
    path = prefix + "/form/" + form["data"]["id"]
    save("form-created.json", form)
    answer = {"target": "b", "checks": ["unit"], "retries": 2.5, "ratio": 0, "confirm": False}
    code, invalid = request("POST", path + "/reply", {"answer": answer})
    save("form-invalid.json", {"status": code, "response": invalid})
    assert code >= 400, invalid
    answer["retries"] = 0
    answer["hidden"] = "secret-default"
    code, accepted = request("POST", path + "/reply", {"answer": answer})
    save("form-reply.json", {"status": code, "response": accepted})
    assert code == 204, accepted
    code, detail = request("GET", path)
    assert code == 200 and detail["data"]["state"]["status"] == "answered", detail
    save("form-detail.json", detail)
    code, external = request("POST", prefix + "/form", {"title": "External step", "fields": [
        {"key": "auth", "type": "external", "url": "https://example.com/auth"}]})
    assert code == 200, external
    external_path = prefix + "/form/" + external["data"]["id"]
    # An external step is completed by its owner; never invent an answer in UI.
    code, _ = request("DELETE", external_path)
    assert code == 204
    code, detail = request("GET", external_path)
    assert code == 200 and detail["data"]["state"]["status"] == "cancelled", detail
    save("form-cancelled.json", detail)
    code, patched = request("PATCH", prefix, {"permissions": [{"action": "fixture", "resource": "*", "effect": "ask"}]})
    assert code == 204, patched
    code, permission = request("POST", prefix + "/permission", {"action": "fixture", "resources": ["fixture-resource"]})
    assert code == 200, permission
    save("permission-created.json", permission)
    if permission["data"]["effect"] == "ask":
        permission_path = prefix + "/permission/" + permission["data"]["id"]
        code, detail = request("GET", permission_path)
        assert code == 200, detail
        save("permission-detail.json", detail)
        code, _ = request("POST", permission_path + "/reply", {"decision": "once"})
        assert code == 204
