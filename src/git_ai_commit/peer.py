"""Unix domain socket peer verification (ADR-0005, docs/06).

Verifies the connecting process shares the expected UID. Depends only
on UID, which is available on every target platform; deliberately does
NOT rely on PID (absent on stock macOS's ``xucred``). Fails closed on
unsupported platforms or any OSError.
"""

from __future__ import annotations

import socket
import struct
import sys


def verify_peer_uid(sock: socket.socket, expected_uid: int) -> bool:
    """Return True iff the peer on ``sock`` runs as ``expected_uid``.

    Never raises for the platform-unsupported case; fails closed
    (returns False) instead.
    """
    if sys.platform == "linux":
        # struct ucred { pid_t pid; uid_t uid; gid_t gid; } -> 3 ints.
        try:
            creds = sock.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
            )
            _pid, uid, _gid = struct.unpack("3i", creds)
            return uid == expected_uid
        except OSError:
            return False

    elif sys.platform == "darwin":
        # struct xucred { uint cr_version; uid_t cr_uid; ... }
        # Read only the first two scalar fields off the front, which are
        # layout-stable across known xucred variants.
        LOCAL_PEERCRED = 0x001  # from <sys/ucred.h>; verify vs target SDK
        try:
            SOL_LOCAL = 0
            raw = sock.getsockopt(SOL_LOCAL, LOCAL_PEERCRED, 8)
            _version, uid = struct.unpack("Ii", raw)
            return uid == expected_uid
        except OSError:
            return False

    else:
        # Unsupported platform: fail closed rather than silently skip.
        return False
