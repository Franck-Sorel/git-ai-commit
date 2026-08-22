# ADR-0009: Prompt engineering first; defer fine-tuning

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Resolves risk #5 in `docs/05-open-risks-and-decisions.md` / `docs/07-project-closeout.md`.

## Context

Generic instruct models can drift into code-completion mode on
diff-shaped input. Fine-tuning on a commit-message dataset would fix
this but requires dataset curation, training infra, and an eval
harness — significant additional engineering beyond this architecture.

## Decision

Ship **prompt engineering only**:

- Explicit system instruction (Conventional Commits, output only the
  remaining message, no code/explanation).
- `stop: ["\n"]` sequence.
- Low `temperature` (0.2).
- A handful of few-shot examples (optional, in the prompt).

Revisit fine-tuning **only if** the shipped base model demonstrably
drifts into code output or verbose non-commit text despite the system
prompt.

## Consequences

- **Positive:** Ship fast with zero training infra.
- **Positive:** The HTTP contract is model-agnostic; swapping models
  later is cheap.
- **Negative:** May need prompt tuning per model; occasionally a model
  still misbehaves — accepted risk for the MVP.

## Related

- ADR-0003 (OpenAI-compatible endpoint / prompt body)
- ADR-0004 (causal decoder-only instruct model)
