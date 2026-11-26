"""Tiny stdlib HTTP API. Shows which dependencies are installed, so a rebuild is visible."""

import importlib.metadata as md
import importlib.util
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GREETING = "hello from api v1"  # edit me: sync+restart
STARTED = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
STACK_INFO = Path("/shared/stack-info.json")


def payload() -> dict:
    deps = sorted(
        d.metadata["Name"].lower() for d in md.distributions() if d.metadata["Name"]
    )
    body = {
        "greeting": GREETING,
        "started": STARTED,
        "packages": deps,
        "stack": json.loads(STACK_INFO.read_text()) if STACK_INFO.exists() else None,
    }
    if importlib.util.find_spec("cowsay"):
        import cowsay

        body["cow"] = cowsay.get_output_string("cow", GREETING)
    if importlib.util.find_spec("pyfiglet"):  # appears after adding pyfiglet + rebuild
        import pyfiglet

        body["figlet"] = pyfiglet.figlet_format("rebuilt!")
    return body


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        data = (
            b'{"ok": true}'
            if self.path == "/api/health"
            else json.dumps(payload(), indent=2).encode()
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:
        if not self.path.endswith("/health"):
            super().log_message(fmt, *args)


if __name__ == "__main__":
    print(f"api starting: {GREETING}")
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
