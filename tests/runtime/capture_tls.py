#!/usr/bin/env python3
"""Verify native managed discovery and HTTPS/base-path REST/SSE/WSS with a local TLS proxy.

Creates an isolated native daemon/profile and self-signed test CA. No personal
configuration or credentials. An empty local catalog disables model execution
and catalog fetching. Requires installed OpenSSL.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    cli = str(Path(args.cli).resolve())
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    profile = Path(tempfile.mkdtemp(prefix="opencode-native-tls-"))
    env = {"PATH": os.environ["PATH"], "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1"}
    for key, directory in {"XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_STATE_HOME": "state", "XDG_CACHE_HOME": "cache",
                           "TMPDIR": "tmp", "OPENCODE_CONFIG_DIR": "config/opencode", "OPENCODE_TEST_HOME": "home"}.items():
        path = profile / directory
        path.mkdir(parents=True, exist_ok=True)
        env[key] = str(path)
    env["NVIM_LOG_FILE"] = str(profile / "nvim.log")
    models = profile / "models.json"
    models.write_text("{}")
    env["OPENCODE_MODELS_PATH"] = str(models)
    env["OPENCODE_DISABLE_MODELS_FETCH"] = "true"
    (Path(env["OPENCODE_CONFIG_DIR"]) / "opencode.json").write_text(json.dumps({
        "experimental": {"policies": [{"action": "provider.use", "resource": "*", "effect": "deny"}]},
    }))
    project = profile / "project"
    project.mkdir()
    subprocess.run(["git", "init", "--quiet", str(project)], env=env, check=True)
    native_port = socket.socket()
    native_port.bind(("127.0.0.1", 0))
    port = native_port.getsockname()[1]
    native_port.close()
    def cli_run(arguments):
        result = subprocess.run([cli] + arguments, env=env, cwd=project, capture_output=True, text=True, timeout=35)
        assert result.returncode == 0, "Native CLI failed: " + result.stderr
        return result
    proxy = None
    try:
        cli_run(["service", "set", "hostname", "127.0.0.1"])
        cli_run(["service", "set", "port", str(port)])
        cli_run(["service", "start"])
        registrations = list((profile / "state/opencode").glob("service*.json"))
        assert len(registrations) == 1, "Native registration missing or ambiguous"
        registration = registrations[0]
        cli_run(["service", "stop"])
        assert not registration.exists(), "Native stop did not remove its registration"
        def nvim_run(script, extra):
            nvim_env = dict(env, OPENCODE_V2_CLI=cli, OPENCODE_V2_PROJECT=str(project), OPENCODE_V2_SERVICE_FILE=str(registration),
                            OPENCODE_V2_OUTPUT=str(output / (script + ".json")), **extra)
            result = subprocess.run(["nvim", "--headless", "--noplugin", "-n", "-i", "NONE", "-u", str(repo / "tests/minimal_init.lua"),
                                     "-l", str(repo / "tests/runtime" / (script + ".lua"))], cwd=repo, env=nvim_env,
                                    capture_output=True, text=True, timeout=90)
            (output / (script + "-output.txt")).write_text(result.stdout + result.stderr)
            assert result.returncode == 0, "Native Neovim verification failed: " + result.stdout + result.stderr
        nvim_run("v2_managed", {})
        info = json.loads(registration.read_text())
        upstream = urllib.parse.urlparse(info["url"])
        key, cert = profile / "tls-key.pem", profile / "tls-ca.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert),
                        "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       capture_output=True, check=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                remote = None
                try:
                    data = b""
                    while b"\r\n\r\n" not in data:
                        part = self.request.recv(8192)
                        if not part:
                            return
                        data += part
                        assert len(data) < 65536
                    first, rest = data.split(b"\r\n", 1)
                    method, target, protocol = first.split(b" ")
                    assert target.startswith(b"/proxy/"), "Base path was omitted"
                    remote = socket.create_connection((upstream.hostname, upstream.port), timeout=10)
                    remote.settimeout(None)
                    remote.sendall(b" ".join([method, target[len(b"/proxy"):], protocol]) + b"\r\n" + rest)
                    def upload():
                        try:
                            while True:
                                chunk = self.request.recv(65536)
                                if not chunk:
                                    break
                                remote.sendall(chunk)
                        except (OSError, ssl.SSLError):
                            pass
                        try:
                            remote.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                    threading.Thread(target=upload, daemon=True).start()
                    while True:
                        chunk = remote.recv(65536)
                        if not chunk:
                            break
                        self.request.sendall(chunk)
                except (OSError, ssl.SSLError):
                    pass
                finally:
                    if remote:
                        remote.close()
        class Proxy(socketserver.ThreadingTCPServer):
            daemon_threads = True
            def get_request(self):
                request, address = super().get_request()
                try:
                    return context.wrap_socket(request, server_side=True), address
                except ssl.SSLError:
                    request.close()
                    raise OSError("TLS peer rejected test certificate")
        proxy = Proxy(("127.0.0.1", 0), Handler)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        nvim_run("v2_tls", {"OPENCODE_V2_SERVER_URL": "https://127.0.0.1:" + str(proxy.server_address[1]) + "/proxy",
                           "OPENCODE_V2_CA_FILE": str(cert), "OPENCODE_V2_PASSWORD": info.get("password", "")})
        print("Native managed and TLS transport verification passed: " + str(output))
    finally:
        if proxy:
            proxy.shutdown()
            proxy.server_close()
        subprocess.run([cli, "service", "stop"], env=env, cwd=project, capture_output=True, timeout=35)
        shutil.rmtree(profile)

if __name__ == "__main__":
    main()
