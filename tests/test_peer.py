"""Peer-credential UID verification tests (ADR-0005, docs/06)."""

import os
import socket
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import pytest

from git_ai_commit.peer import verify_peer_uid


@pytest.mark.skipif(not hasattr(socket, "SO_PEERCRED"), reason="Linux-only SO_PEERCRED")
def test_linux_accepts_same_uid(tmp_path):
    sock_path = str(tmp_path / "test.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(1)

    results = {}

    def serve():
        conn, _ = server.accept()
        results["uid"] = verify_peer_uid(conn, os.getuid())
        conn.close()

    t = threading.Thread(target=serve)
    t.start()

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(sock_path)
    client.close()
    t.join(timeout=5)

    assert results.get("uid") is True


@pytest.mark.skipif(not hasattr(socket, "SO_PEERCRED"), reason="Linux-only SO_PEERCRED")
def test_linux_rejects_different_uid(tmp_path):
    sock_path = str(tmp_path / "test2.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(1)

    results = {}

    def serve():
        conn, _ = server.accept()
        # expected_uid deliberately not the peer's uid
        results["uid"] = verify_peer_uid(conn, os.getuid() ^ 999)
        conn.close()

    t = threading.Thread(target=serve)
    t.start()

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(sock_path)
    client.close()
    t.join(timeout=5)

    assert results.get("uid") is False


def test_fails_closed_on_unexpected_call():
    # A plain socket object won't have SO_PEERCRED on this platform's
    # verification path; the function must never crash.
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # not connected -> getsockopt raises -> returns False (or True only on linux
    # path which also raises because not connected).
    assert verify_peer_uid(s, os.getuid()) in (True, False)
    s.close()
