# Specs

Design documents written before the code. Each one states a problem, the
decision taken, and acceptance criteria precise enough that the implementation
either satisfies them or does not.

A spec is not a roadmap entry. It exists because the change is large enough
that discovering the design while writing bash would produce a worse design.
Small fixes go straight to a commit.

## Index

| # | Spec | Status |
|---|---|---|
| [0001](0001-terminal-output.md) | Collapse-on-pass terminal output | Draft |
| [0002](0002-reports.md) | Markdown and HTML reports | Draft |
| [0003](0003-agentic-hygiene.md) | Agent configuration audit phase | Draft |
| [0004](0004-rule-catalog.md) | Rule catalog format and IDs | Implemented |

Status is one of `Draft`, `Accepted`, `Implemented`, `Superseded`, `Withdrawn`.
A spec stays in the repository after it ships — the reasoning is the point, and
`Implemented` specs explain why the code looks the way it does. A `Withdrawn`
spec is more useful than a deleted one, because the next person to have the
idea gets the reason it was dropped.

## Writing a spec

Copy [TEMPLATE.md](TEMPLATE.md). Keep it shorter than you want to.

Two rules that matter more than the rest:

**Acceptance criteria must be checkable by something other than an opinion.**
"Output is cleaner" is not a criterion. "A run with zero findings prints at most
one line per phase" is.

**Inherit the constraints, don't restate them.** Every spec is bound by
[CONTRIBUTING.md](../CONTRIBUTING.md) — bash 3.2, config as data never code,
read-only modes staying read-only, `set -euo pipefail` traps, text labels
alongside colour. A spec only mentions a constraint when it interacts with it in
a way that isn't obvious.

## Relationship to the threat model

[SECURITY.md](../SECURITY.md) is the authority on what this tool defends
against. A spec that adds a check must say which threat it addresses and cite
the layer, or explain why it belongs in a tool whose stated scope is supply
chain integrity. Scope creep in a security tool is how it becomes a linter
nobody trusts.
