#!/usr/bin/env python3
"""Disposable MCP stdio fixture; no filesystem, network, or credential access."""
import json
import sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}, "resources": {}},
                  "serverInfo": {"name": "opencode-nvim-test", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "echo", "description": "Test echo", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
    elif method == "resources/list":
        result = {"resources": []}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": request["params"]["arguments"].get("text", "")}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
