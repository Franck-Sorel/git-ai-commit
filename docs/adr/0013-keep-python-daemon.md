# ADR-0013: Keep the daemon in Python (reject Rust/Go migration)

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Supersedes/refines:** ADR-0002 (Python daemon), ADR-0005 (peer-cred), `docs/06`, `docs/07`.
- **Source:** Decision review of two competing proposals — "Rewrite the daemon in Rust" vs. "Optimize Python (uvloop + PyOxidizer)" — with 2026 factual verification of their supporting claims.

## Context

A review debate proposed migrating the daemon to Rust, or "optimizing" Python with uvloop + PyOxidizer, claiming material latency and deployment gains for the "ghost text" UX. Both proposals rest on factual claims about Python-vs-Rust performance and Python packaging that need verification before they can drive a rewrite.

## Verified facts (2026 re-check)

| Claim | Verdict | Evidence |
|---|---|---|
| PyOxidizer gives a reliable single-binary Python distribution | **WRONG** | Maintainer (indygreg) declared the project "uncertain, possibly dead" (2024-03-18); no meaningful updates since Jan 2023; Anki migrated away (ankitects/anki#3081). Building a distribution story on it is unsafe. |
| uvloop "falls back to asyncio on macOS" | **WRONG** | uvloop is built on libuv (Node.js's engine, cross-platform); PyPI and conda-forge both list macOS-arm64 / macOS-64 as supported. No macOS degradation. |
| uvloop is required for acceptable daemon latency | **NOT LOAD-BEARING** | uvloop gives 2-4x on *high-concurrency* benchmarks; for an I/O-bound proxy whose per-request wall time is dominated by 150-500ms inference, measured gains are ~5% or imperceptible (Python.org / r/Python discussions). |
| llama-server benefits from HTTP/2 | **RED HERRING** | llama-server is HTTP/1.1 + keep-alive, exposing `/v1/completions` (ADR-0003). HTTP/1.1 keep-alive already removes the per-request TCP handshake the HTTP/2 argument targets. |
| Rust IPC/socket is meaningfully faster than Python here | **NOT LOAD-BEARING** | Raw ping-pong µs numbers don't matter for a persistent, connection-pooled async client spending >95% of time `await`-ing inference. Python asyncio, Go, and Rust converge on wall-clock for this IO-bound shape. |
| Peer-credential verification is a Rust advantage | **FALSE** | The macOS `xucred`-has-no-PID limitation is a kernel/libc fact every language hits (Go hit the identical wall, per golang/go#27613). ADR-0005 depends only on UID, retrievable in Python easily. |

## Decision

Keep the daemon in **Python 3.x (asyncio + aiohttp)**, as already implemented (ADR-0002). Do **not** migrate to Rust or Go for the MVP, and do **not** adopt uvloop or a single-file-packaging rewrite.

Reasoning:

1. **The daemon is an I/O-bound proxy, not a compute-bound service** (`docs/04` §4): accept socket → read a small JSON line → one HTTP call → write a small JSON line. It spends ~all of its time blocked on `llama-server` inference. Python, Go, and Rust converge on wall-clock for this shape once the process is warm.
2. **The dominant, unmeasured term is inference latency** (`docs/07` item 1, OPEN). Every millisecond argued in both proposals is about a slice of a pie whose total has not been measured. Optimizing the smaller, controllable term (daemon) while the larger term (TTFT 150-500ms) is unbenchmarked is misplaced priority. **Build, measure, then optimize.**
3. **Deployment concerns are already solved** by modern Python tooling: `uv` (standalone binary, no preinstalled Python needed, works on locked-down machines, `uv tool install`) — a better story than the abandoned PyOxidizer. The project already ships a `pip install -e .` path and a venv for development.
4. **Dev velocity / maintainability** win for Python for the target audience (Zsh plugin developers), and the workload has no CPU-bound component that would make the GIL a constraint.

## When this WOULD change (future triggers that justify re-evaluation)

Only re-open this decision if one of these is true after measurement:

- Profile-driven evidence shows the daemon contributes >5% of end-to-end latency on real hardware (unlikely per the math above). If so, prefer **Go** over Rust for a static binary + simple concurrency, not Rust's ownership/lifetime overhead for code this structurally simple.
- The daemon must **embed inference directly** (drop llama-server), making it CPU-bound — a different architecture and a separate ADR.
- Target runtime is an environment where a Python interpreter genuinely cannot be installed (the only case Rust's purely-static binary is non-negotiable).

## Consequences

- **Positive:** No rewrite; latency risk concentrated where it belongs (inference, trigger strategy — per ADR-0006).
- **Positive:** Avoids two factual errors: relying on dead PyOxidizer, and repeating the false "uvloop lacks macOS support" line.
- **Positive:** `SO_PEERCRED`/`LOCAL_PEERCRED` already implemented in Python (ADR-0005) and re-verified.
- **Negative:** Renouncing the marginal startup/IPC gains of a native binary — accepted as imperceptible for the UX.
- **Negative:** The "single static binary, `cargo install`" distribution story is not available; mitigated by `uv`-based install.

## Related

- ADR-0002 (Python daemon), ADR-0005 (peer-cred in Python),
  ADR-0006 (trigger strategy), `docs/07` item 1 (latency is OPEN — measure).
