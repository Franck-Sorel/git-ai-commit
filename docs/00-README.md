# AI Ghost-Text Commit Assistant — Project Documentation

This is the documentation set for the "ghost-text" AI commit-message
completion system for Zsh (a Copilot-style inline suggestion UX for
`git commit -m "..."`, built on Zsh's Line Editor, a local `llama.cpp`
server, and a small persistent daemon).

It was produced by fact-checking the original proposal and its
"refined" follow-up against **primary sources**: the Zsh manual
(`zshzle(1)`), the Zsh source-level workers list, the
`zsh-autosuggestions` reference implementation (the closest
real-world analogue of this feature), and the current `llama.cpp`
`tools/server` documentation. Claims that could not be verified, or
that were found to be wrong or outdated, are called out explicitly
rather than restated as fact.

## Documents

| File | Contents |
|---|---|
| [`01-fact-check-and-refinements.md`](./01-fact-check-and-refinements.md) | Line-by-line verification of the two source documents against primary sources. What was correct, what was wrong, what is version-dependent. |
| [`02-architecture-high-level.md`](./02-architecture-high-level.md) | System-level architecture: components, responsibilities, data flow, why each decision was made. |
| [`03-architecture-low-level.md`](./03-architecture-low-level.md) | Concrete state machine, IPC protocol, ZLE widget contracts, timing budget. |
| [`04-implementation-guide.md`](./04-implementation-guide.md) | Working code: Zsh plugin (using `zsh/zpty`, not a FIFO-polling hack), Python daemon, `llama-server` invocation. |
| [`05-open-risks-and-decisions.md`](./05-open-risks-and-decisions.md) | Things that remain genuinely uncertain, need local testing, or are architecture trade-offs rather than facts. |

## Headline correction

The single most consequential fix versus both source documents: **do
not build the async transport on a hand-rolled FIFO + polling loop.**
That is not how any production Zsh plugin does this, it is not
reliable, and it will hang or corrupt state under rapid typing. Use
the `zsh/zpty` module, which is the actual mechanism `zsh-autosuggestions`
(millions of installs, in continuous production use since ~2013) uses
for exactly this problem. Details in `01-fact-check-and-refinements.md`
and working code in `04-implementation-guide.md`.
