#!/usr/bin/env python3
"""Per-shell worker (ADR-0007): bridges the zpty stdio to the daemon's
Unix socket.

Runs INSIDE the pty that ``zsh/zpty`` manages. Reads newline-delimited
JSON from stdin (written by Zsh via ``zpty -w``), forwards each request
to the daemon over a fresh Unix socket connection, and writes the
daemon's single-line JSON response back to stdout (read by the ``zle -F``
callback).

The worker must never hang Zsh: if the daemon is unreachable it returns
a ``status: "error"`` response immediately. Stdlib only.
"""

import json
import os
import socket
import sys

DEFAULT_SOCKET_PATH = os.environ.get(
    "XDG_RUNTIME_DIR", f"/tmp/git-ai-commit-{os.getuid()}"
) + "/daemon.sock"


def _socket_path() -> str:
    # Prefer the env-controlled path (ADR-0010), else the XDG default.
    return os.environ.get("GIT_AI_SOCKET_PATH", DEFAULT_SOCKET_PATH)


def _forward(line: str) -> str:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(10.0)
            sock.connect(_socket_path())
            sock.sendall((line + "\n").encode("utf-8"))
            sock.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks).decode("utf-8")
    except OSError as exc:
        try:
            req = json.loads(line)
            req_id = req.get("id")
        except json.JSONDecodeError:
            req_id = None
        return json.dumps(
            {"id": req_id, "status": "error", "message": f"daemon unreachable: {exc}"}
        )


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        response = _forward(line)
        sys.stdout.write(response.strip() + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
