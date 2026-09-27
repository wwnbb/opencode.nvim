# OpenCode 2.0.11 runtime evidence

Captured 2026-09-21 with `tests/runtime/capture_v2.py`, native darwin-arm64 CLI
2.0.11, separate XDG config/data/state/cache, TMPDIR and OPENCODE_TEST_HOME.
All project/profile paths are replaced by `<PROFILE>`. The server was private,
Basic authenticated, bound to loopback on an OS-selected port, and its exit was
observed. No user configuration or personal credentials were inherited.

The user-authorized model was `opencode/mimo-v2.5-free` (OpenCode Zen).
The catalog reported zero input/output/cache cost. It produced the requested
text and an assistant reasoning block. These are actual HTTP and SSE records,
not reconstructed DTOs. `http.json` omits the large unrelated catalog responses;
`model.json` retains only the selected model.

The repeated prompt ID returned HTTP 200 with the original admission record.
This alone does not prove every retry/reconnect scenario or different-payload
conflict behavior. Those cases still need dedicated checks.

Reproduce using an explicit CLI binary and a fresh output directory:

```sh
python3 tests/runtime/capture_v2.py --cli /path/to/opencode \
  --output /tmp/opencode-v2-capture --model opencode/mimo-v2.5-free
```

Omit `--model` to exercise startup, auth, catalogs and session CRUD without
calling a model. The harness retains its temporary profile for diagnostics and
terminates only the process it started.
