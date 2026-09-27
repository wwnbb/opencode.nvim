import sys
import time
from pathlib import Path
from urllib.parse import quote


def run(request, save, location):
    name = "test-mcp"
    endpoint = "/api/experimental/mcp/" + quote(name, safe="")
    config = {"type": "local", "command": [sys.executable, str(Path(__file__).with_name("mcp_stdio.py"))],
              "disabled": True, "protocol": "legacy"}
    code, data = request("PUT", endpoint + location, {"config": config})
    assert code == 204, (code, data)
    code, listing = request("GET", "/api/mcp" + location)
    assert code == 200, listing
    save("mcp-disabled.json", listing)
    assert next(item for item in listing["data"] if item["name"] == name)["status"]["status"] == "disabled"
    code, data = request("POST", endpoint + "/connect" + location, {})
    assert code == 204, (code, data)
    deadline = time.monotonic() + 15
    while True:
        code, listing = request("GET", "/api/mcp" + location)
        item = next(item for item in listing["data"] if item["name"] == name)
        if item["status"]["status"] != "pending" or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    save("mcp-connected.json", listing)
    assert item["status"]["status"] == "connected", item
    code, data = request("POST", endpoint + "/disconnect" + location, {})
    assert code == 204, (code, data)
    code, listing = request("GET", "/api/mcp" + location)
    save("mcp-disconnected.json", listing)
    assert next(item for item in listing["data"] if item["name"] == name)["status"]["status"] == "disabled"
    code, data = request("DELETE", endpoint + location)
    assert code == 204, (code, data)
    code, data = request("POST", endpoint + "/connect" + location, {})
    save("mcp-missing.json", {"status": code, "response": data})
    assert code >= 400, (code, data)
