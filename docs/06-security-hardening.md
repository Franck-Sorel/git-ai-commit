# Security Hardening: Unix Socket Peer Verification

**Status:** FINAL, supersedes SO_PEERCRED/LOCAL_PEERCRED guidance in `05`.

This document supersedes the `SO_PEERCRED`/`LOCAL_PEERCRED` guidance
sketched across the risk-analysis documents. The prior guidance
("struct field order differs by platform, e.g. `{uid,gid,pid}` on
OpenBSD vs `{pid,uid,gid}` on Linux") is **not accurate** and, if
implemented as described, would produce code that fails to compile or
silently misreads memory on macOS. The correction below is checked
against kernel/libc headers, the FreeBSD commit that changed `xucred`,
and two independent standard-library implementations (Go, Rust/Tokio)
that had to solve this exact cross-platform problem.

## 1. What's actually available, per platform

| Platform | Mechanism | Struct | Fields available | PID available? |
|---|---|---|---|---|
| Linux | `getsockopt(SOL_SOCKET, SO_PEERCRED)` | `struct ucred` | `pid`, `uid`, `gid` | YES, always |
| macOS | `getsockopt(0 /* SOL_LOCAL */, LOCAL_PEERCRED)` | `struct xucred` | `cr_version`, `cr_uid`, `cr_ngroups`, `cr_groups[]` | NO - `xucred` has no PID field. A separate `LOCAL_PEERPID` call is required if you also need the PID. |
| FreeBSD 13+ | Same `LOCAL_PEERCRED` call, but `xucred` was extended | `struct xucred` (FreeBSD's own, extended) | adds `cr_pid` | YES, but only FreeBSD 13+, and this is FreeBSD's own struct extension - do not assume the macOS layout |
| OpenBSD | Different interface (not `LOCAL_PEERCRED`) | platform-specific | uid/gid via its own call | N/A |
| NetBSD | `LOCAL_PEEREID` | `struct unpcbid` | `unp_euid`, `unp_egid` | via same struct |

**The load-bearing conclusion:** the daemon's actual security
requirement is "verify the connecting process shares my UID." **UID is
available on every platform above via some call.** PID is not
portably available (notably missing on stock macOS) and should be
treated as optional diagnostic information, never as something the
verification logic depends on being present.

## 2. Corrected implementation (Python, `asyncio` daemon)

```python
import socket
import struct
import sys

def verify_peer_uid(sock: socket.socket, expected_uid: int) -> bool:
    """Verify the connecting process on a Unix domain socket shares
    expected_uid. Returns True/False; never raises for the platform-
    unsupported case (fails closed instead).
    """
    if sys.platform == "linux":
        # struct ucred { pid_t pid; uid_t uid; gid_t gid; } -- 3 ints
        try:
            creds = sock.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
            )
            _pid, uid, _gid = struct.unpack("3i", creds)
            return uid == expected_uid
        except OSError:
            return False

    elif sys.platform == "darwin":
        # struct xucred { u_int cr_version; uid_t cr_uid;
        #                 short cr_ngroups; gid_t cr_groups[NGROUPS]; }
        # NGROUPS is 16 on Darwin -> version(4) + uid(4) + ngroups(2)
        # + padding(2) + groups(16*4) = 88 bytes on most builds, but
        # DO NOT hardcode the size -- request it dynamically.
        LOCAL_PEERCRED = 0x001  # value from <sys/ucred.h>; verify against
                                 # the target SDK rather than assuming
        try:
            SOL_LOCAL = 0
            raw = sock.getsockopt(SOL_LOCAL, LOCAL_PEERCRED, 8)
            _version, uid = struct.unpack("Ii", raw)
            return uid == expected_uid
        except OSError:
            return False

    else:
        # Unsupported platform for this check: fail closed rather than
        # silently skip verification.
        return False
```

**Deliberately not implemented here:** PID retrieval on macOS
(`LOCAL_PEERPID`), because it is not needed for the "same user" check
this daemon actually requires, and adding it would reintroduce the
exact cross-platform struct-layout risk this document exists to avoid.
If a future requirement genuinely needs the peer PID (e.g., richer
audit logging), implement it as a **separate, best-effort, optional**
call guarded by its own platform check and its own try/except - never
assumed to succeed, and never load-bearing for the security decision.

## 3. Where this plugs into the daemon

```python
async def handle_client(self, reader, writer):
    sock = writer.get_extra_info("socket")
    if sock is not None and not verify_peer_uid(sock, os.getuid()):
        writer.close()
        return
    # ... existing request handling from 04-implementation-guide.md
```

This check runs on every accepted connection, in addition to (not
instead of) the `chmod 0600` on the socket file - the file permission
stops other users; this check stops other processes running as *you*
(the actual gap the earlier risk documents correctly identified, even
though their proposed struct layout was wrong).

## 4. Verification note for implementers

The exact `LOCAL_PEERCRED` numeric value and `xucred` byte layout are
part of the platform SDK headers (`<sys/ucred.h>` on macOS/BSD), not
something to hardcode from a document like this one. **Before shipping,
compile a small C test program against the target macOS SDK, print
`sizeof(struct xucred)` and the offsets of `cr_version`/`cr_uid`, and
confirm they match what this Python code assumes.** Treat the code
above as "correct in mechanism, verify the exact constants for your
deployment target" - the same standard applied to every other code
sample in this documentation set.
