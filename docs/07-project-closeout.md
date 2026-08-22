# Project Closeout: Final Status of Open Risks

**Status:** FINAL. Read this one last. Supersedes/refines `05`.

This closes out `05-open-risks-and-decisions.md` against the follow-up
research rounds, incorporating the correction in `06-security-hardening.md`.
Status labels reflect what's actually verified versus what's a reasonable
but still-unmeasured estimate.

## Status table

| # | Item | Status | Basis |
|---|---|---|---|
| 1 | Latency | **OPEN - requires local benchmarking** | Published figures for 1-3B GGUF models on CPU cluster in a wide **~5-50 tok/s** range depending on hardware, thread count, and quantization. No substitute for running `llama-bench` on the actual target hardware. |
| 2 | `zpty` portability | **OPEN - environment-dependent, mitigated by design** | Add a `zpty` self-test at plugin load (spawn a trivial echo command, verify round-trip output within a timeout) and degrade to "no suggestions, no shell disruption" if it fails. |
| 3 | Worker lifecycle | **RESOLVED (design decision)** | Hybrid model - persistent daemon + lightweight per-shell client, with explicit broken-socket detection and a user-facing restart prompt. |
| 4 | Trigger strategy | **RESOLVED (design decision), latency-conditional** | Whitespace-triggered as the default, per-keystroke as an opt-in gated on a **locally measured** time-to-first-token below a threshold (~100-150ms heuristic, not a benchmarked cutoff). |
| 5 | Fine-tuning vs. prompt engineering | **RESOLVED (design decision)** | Ship prompt-engineering-only; revisit fine-tuning only if the shipped model demonstrably drifts into code output or verbose non-commit-message text despite explicit system-prompt constraints. |
| 6 | Security - socket peer verification | **RESOLVED, implementation corrected** | `chmod 0600` plus UID verification via `SO_PEERCRED` (Linux) / `LOCAL_PEERCRED` (macOS). The verification logic depends only on UID, which is portably available; PID is explicitly **not** relied upon. See `06-security-hardening.md`. |
| 7 | Model choice | **RESOLVED (design decision)** | Capability-based requirement (causal decoder-only, GGUF-convertible, configurable path, target throughput on the deployer's own hardware) rather than a pinned model name. |

## What "Resolved" means here, precisely

Items 3, 4 (the decision), 5, 6, and 7 are resolved **as engineering
decisions** - there was no external fact to verify, only a choice to
make among documented trade-offs, and a reasonable choice has now been
made and justified. Item 6 additionally required a factual correction
before its proposed implementation would have been safe to ship.

Items 1 and 2 remain genuinely open because they depend on
**empirical conditions outside this documentation's control** - the
deployer's specific hardware, OS version, and Zsh build.

## Outstanding action items for whoever implements this

1. Run `llama-bench` with the chosen model/quantization on the actual
   target machine(s) before committing to a debounce interval or
   trigger strategy threshold.
2. Add and test the `zpty` self-test / graceful-degradation path on
   both a Linux and a macOS target before relying on it in production.
3. Before shipping the socket peer-verification code in
   `06-security-hardening.md`, compile and run the small C
   struct-inspection test it describes against the actual target
   macOS SDK version.
4. Re-check current model availability/quality at implementation time
   rather than trusting any specific model name.
