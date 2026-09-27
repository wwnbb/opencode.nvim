"""Run native visual/performance checks and a deterministic local SSE smoke.

Needs Pillow, msgpack and installed Rust parser/queries on OPENCODE_CODE_RTP.
Usage: python tests/runtime/run_code_highlights.py /tmp/code-highlights
"""
import json
import os
from pathlib import Path
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import native_ui


def main():
    repo = Path(__file__).resolve().parents[2]
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, NVIM_LOG_FILE=str(output / "nvim.log"), OPENCODE_CODE_REPORT=str(output / "timings.json"))
    result = native_ui.run(repo, "code_highlights.lua", env, output)
    assert result.returncode == 0, result.stderr
    print(result.stdout)
    resume = threading.Event()
    connections = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/continue":
                resume.set()
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")
                return
            if self.path != "/api/event":
                self.send_error(404)
                return
            connections.append(self.path)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            sequence = 0

            def emit(kind, **data):
                nonlocal sequence
                sequence += 1
                event = dict(id=f"code-fixture-{sequence}", type="session." + kind, created=sequence,
                             data=dict(sessionID="code-sse", assistantMessageID="answer", ordinal=0, **data))
                self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.06)

            emit("step.started", started=1, agent="build", model=dict(providerID="fixture", id="fixture"))
            emit("text.started")
            chunks = ["`", "``ru", "st\n", "fn main() {\n", '    let message = "Привет', '";\n',
                      '    println!("{message}");\n', "}\n// before closing"]
            for chunk in chunks:
                emit("text.delta", delta=chunk)
            assert resume.wait(15), "Neovim did not confirm open-block highlights"
            emit("text.delta", delta="\n```\nAfter the code.")
            emit("text.ended", text="".join(chunks) + "\n```\nAfter the code.")
            time.sleep(0.2)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = native_ui.run(repo, "code_highlights_sse.lua", dict(env, OPENCODE_CODE_SSE_PORT=str(server.server_port)), output)
        assert result.returncode == 0, result.stderr
        assert connections == ["/api/event"], connections
        print(result.stdout)
        (output / "sse-result.json").write_text(json.dumps(dict(real_tcp_sse=True, open_before_completion=True,
                                                             final_prose_unhighlighted=True)))
    finally:
        resume.set()
        server.shutdown()
        server.server_close()
    print((output / "timings.json").read_text())


if __name__ == "__main__":
    main()
