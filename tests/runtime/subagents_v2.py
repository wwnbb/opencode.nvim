"""Record native delegated-session linkage, using an explicitly chosen model."""
import time


def run(request, save, prefix):
    code, admission = request("POST", prefix + "/prompt", {"text": "Use the subagent tool to delegate TWO separate tasks to the explore agent, with the same short description 'Small test'. First task: reply CHILD_ONE without reading files or using other tools. Second task: reply CHILD_TWO without reading files or using other tools. Both tasks must use the current MiMo v2.5 Free model. Wait for both results and then reply PARENT_DONE.", "delivery": "queue"})
    assert code == 200, admission
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        code, history = request("GET", prefix + "/message")
        assert code == 200, history
        idle = next((m for m in history["data"] if m["type"] == "idle"), None)
        if idle:
            assert idle["outcome"] == "succeeded", history
            break
        time.sleep(0.25)
    else:
        raise AssertionError("Delegation did not finish")
    save("subagent-parent.json", history)
    tools = [c for m in history["data"] for c in m.get("content", []) if c["type"] == "tool"]
    assert any(c["name"] == "subagent" for c in tools), tools
    sid = prefix.rsplit("/", 1)[-1]
    code, children = request("GET", "/api/session?parentID=" + sid)
    save("subagent-children.json", children)
    assert code == 200 and len(children["data"]) >= 2, children
    for i, child in enumerate(children["data"]):
        child_prefix = "/api/session/" + child["id"]
        code, child_history = request("GET", child_prefix + "/message")
        assert code == 200, child_history
        save(f"subagent-child-{i}.json", {"session": child, "history": child_history})
        assert child["model"]["providerID"] == "opencode" and child["model"]["id"] == "mimo-v2.5-free", child
