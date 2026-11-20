"""Dos orígenes loopback: A redirige a B; ninguna credencial puede llegar a B."""
import os
import re
import subprocess
import sys
import threading
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def check_centralization():
    root = Path(__file__).resolve().parent.parent
    # Solo tipos de RESPUESTA: no construyen clientes ni envian peticiones.
    response_only = {
        "providers/src/connector.zig",
        "providers/src/adapters/anthropic.zig",
        "providers/src/adapters/gemini.zig",
        "providers/src/adapters/openai.zig",
    }
    checked = 0
    for folder in ("providers", "core"):
        for path in (root / folder).rglob("*.zig"):
            relative = path.relative_to(root).as_posix()
            if relative == "providers/src/http/client.zig":
                continue
            source = "\n".join(line.split("//", 1)[0] for line in path.read_text(encoding="utf-8").splitlines())
            aliases = {"http", "std.http"}
            aliases.update(re.findall(r'\bconst\s+(\w+)\s*=\s*(?:std|@import\("std"\))\.http\s*;', source))
            for alias in aliases:
                for match in re.finditer(r'\b' + re.escape(alias) + r'\.Client\b', source):
                    if relative in response_only and source[match.end():].startswith(".Response"):
                        continue
                    raise RuntimeError(f"Transporte HTTP sin centralizar: {relative}:{source[:match.start()].count(chr(10)) + 1}")
            checked += 1
    if checked == 0:
        raise RuntimeError("Centralizacion: no se inspeccionaron fuentes")
    print(f"SEC_RED_CENTRALIZATION_FILES={checked}", flush=True)


def main():
    command = sys.argv[1:]
    allow_unused = command[0] == "--allow-unused"
    if allow_unused:
        command = command[1:]
    # El stdout puede ser el protocolo binario --listen de Zig.
    sys.stdout = sys.stderr
    check_centralization()
    # Siempre controlar A y B; reemplazar cualquier URL heredada en el hijo.
    requests_a = []
    requests_b = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def handle_request(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            records = requests_a if self.server is server_a else requests_b
            # Solo nombres de cabecera; nunca registrar valores de credenciales.
            secret_bytes = sum(value.count("fixture-key") * len(b"fixture-key") for value in self.headers.values()) + body.count(b"fixture-key") * len(b"fixture-key") + self.path.count("fixture-key") * len(b"fixture-key")
            records.append((self.command, list(self.headers), self.path, secret_bytes))
            redirects = self.server is server_a and self.path != "/same-origin-sink"
            self.send_response(302 if redirects else 200)
            if redirects and self.path.endswith("/same-origin"):
                self.send_header("Location", "/same-origin-sink")
            elif redirects:
                destination = "public" if self.path.endswith("/public") else "sink"
                self.send_header("Location", f"http://127.0.0.1:{server_b.server_port}/{destination}")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        do_GET = do_POST = handle_request

    with ExitStack() as stack:
        server_b = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server_a = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        for server in (server_b, server_a):
            stack.callback(server.server_close)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            stack.callback(thread.join)
            stack.callback(server.shutdown)
        env = os.environ.copy()
        env["BEATS_SEC_RED_URL"] = f"http://127.0.0.1:{server_a.server_port}/redirect"
        result = subprocess.run(command, env=env, check=False)
        if not requests_a and allow_unused:
            print("SEC_RED_FIXTURE_UNUSED: el filtro no ejercita redirecciones", flush=True)
            return result.returncode
        print(f"A_REQUESTS={len(requests_a)} B_REQUESTS={len(requests_b)}", flush=True)
        print(f"B_CREDENTIALS={sum(bool(r[3]) for r in requests_b)} B_PRIVATE_REQUESTS={sum(r[2] != '/public' for r in requests_b)}", flush=True)
        print(f"B_SECRET_BYTES={sum(r[3] for r in requests_b)}", flush=True)
        for method in ("GET", "POST"):
            print(f"A_{method}={sum(r[0] == method for r in requests_a)}", flush=True)
        if not requests_a or requests_b:
            print("FAIL: no se ejercitó A o una petición alcanzó B", flush=True)
            return 1
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
