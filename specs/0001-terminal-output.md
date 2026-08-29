# 0001 — Collapse-on-pass terminal output

| | |
|---|---|
| **Status** | Draft |
| **Threat model layer** | None — presentation. But see *Why this is a security concern* below. |
| **Breaking** | No. `--json` output is unchanged; only human-facing stdout moves. |

## Problem

A clean run currently prints around 120 lines, almost all of them saying that
nothing is wrong. Seventeen phases each announce every check they perform, so
ten trusted Homebrew taps produce ten `tap OK:` lines and five boot-integrity
checks produce five more.

The findings — the only lines a reader needs — are interleaved at the same
visual weight as the passes. A `[warn]` about two unsigned LaunchDaemons sits
between `[sec] SSV snapshots present` and `[sec] FileVault: enabled`, indented
the same, prefixed by a label of the same length.

### Why this is a security concern

[CONTRIBUTING.md](../CONTRIBUTING.md) already states the principle: *"A check
that fires on a healthy machine teaches people to ignore the output, which is
worse than not having the check."* Volume does the same thing more slowly. A
tool that prints a hundred lines of good news trains its user to stop reading
before the bad news, which makes the finding that matters functionally
invisible. This is the same failure as a false positive, arrived at by a
different route.

## Goals

- A run with no findings fits on one screen without scrolling.
- Findings are distinguishable from passes at a glance, without reading the text.
- The end-of-run summary is the primary artefact, not a footer.
- Nothing is lost: the full detail remains in the log file, and `--verbose`
  restores it to the terminal.

## Non-goals

- **Spinners, progress bars, or any redraw.** Phase markers exist precisely
  because a redirected run must read back as a clean list; that constraint is
  unchanged. No carriage returns, no cursor movement.
- **A TUI.** No alternate screen buffer, no interactivity. This tool runs in CI
  and over SSH.
- **Nerd fonts or icon glyphs.** `✓` and `⚠` are already used and are widely
  renderable. Nothing is added that fails on a default terminal.
- **Changing what is checked.** This spec moves bytes, not logic.

## Design

### Per-phase collapse

Each phase accumulates its check results and prints once, on completion.
Passing checks collapse to a single line naming them; failures expand.

Clean phase:

```
[1/18] ENVIRONMENT INTEGRITY                                        4.2s
  ✓ homebrew remote · taps 10/10 · SIP · Gatekeeper · PATH
```

Phase with findings:

```
[2/18] BOOT INTEGRITY                                               5.1s
  ✓ kexts · SSV (1 snapshot) · firmware · FileVault
  ⚠ launchdaemons — 2 new since baseline
      com.vendor-mdm.UpdateScheduler.plist          UNSIGNED
      com.vendor-proxy.ServiceController.plist                UNSIGNED
```

The passing line is a single `✓` followed by check names joined by ` · `. A
count in parentheses replaces enumeration where the individual items are
uninteresting (`taps 10/10`, not ten lines). Findings get their own line and
carry their detail indented beneath.

Elapsed time is right-aligned per phase. It is diagnostic: a phase that
normally takes 200ms and now takes 40s is a signal, and today that is invisible.

### Buffering

`sec`/`ok` calls inside a phase no longer print immediately. They append to a
per-phase buffer; `phase_end` renders it. `warn` and `err` continue to print as
they occur, because a run that hangs or is interrupted must still have shown
what it found. This asymmetry is deliberate: good news can wait, bad news
cannot.

Consequence: a `sec` call in a subshell or pipeline cannot append to the buffer,
for the same reason counts are read back out of the log file rather than kept in
shell variables. The buffer is therefore also derived from the log — `phase_end`
greps the lines this phase appended. This keeps the existing pattern rather than
introducing a second, more fragile one.

### `--verbose`

Restores today's behaviour: every check prints its own line as it runs, no
collapsing. Intended for debugging a check that is misbehaving, and for anyone
who prefers the old output. `--verbose` and `--json` together is valid; verbose
affects only the human stream on fd 3.

### Summary

The summary becomes a findings table, following the shape `osv-scanner` and
`grype` use — a prose count first, so the reader knows the scale before parsing
a table, then the table.

```
────────────────────────────────────────────────────────────────────────
  update-toolchain  dry-run · 3m 12s
────────────────────────────────────────────────────────────────────────
  4 subsystems reported 12 findings — 3 error, 9 warning
  9 have a documented remediation.

  SEVERITY  CHECK                    SUBJECT                  FIX
  error     mcp.secret-plaintext     deploy-api/DEPLOY_TOKEN…   move to keychain
  error     mcp.tls-disabled         deploy-api               drop NODE_TLS_RE…
  error     sha.unexplained-change   /opt/homebrew/bin/pyt…   verify provenance
  warning   brew.doctor              node@20 deprecated       find replacement
  …
────────────────────────────────────────────────────────────────────────
  verdict   ACTION REQUIRED
  log       ~/.local/share/update-toolchain/20260825T034825Z.log
  shas      ~/.local/share/update-toolchain/binary-shas.txt
────────────────────────────────────────────────────────────────────────
```

The table is drawn with spaces and a header row, not box-drawing characters.
Rationale: box-drawing needs the terminal width to be known and the content to
be measured to align, and gets it wrong on narrow terminals in a way that looks
broken rather than merely plain. Columns are truncated with `…` at a fixed
width. `SEVERITY` repeats the word rather than relying on colour, per the
existing rule that no status is carried by colour alone.

The `CHECK` column requires stable identifiers, which do not exist yet — see
[0004](0004-rule-catalog.md). Until that lands, existing findings render with an
empty `CHECK` cell rather than blocking this spec.

### What does not change

- `--json` structure, exit codes, and the `--fail-on` gate.
- Colour policy: `--color=auto|always|never`, `NO_COLOR`, off when not a TTY.
- The log file remains verbose regardless of terminal verbosity. It is the audit
  trail; collapsing it would defeat its purpose.
- Every status keeps a text label.

### Rejected alternatives

**A `--quiet` flag that suppresses passes, leaving today's output as default.**
Rejected: it makes the good behaviour opt-in, so the default remains the one
that trains people not to read. If collapsed output is right, it is right by
default.

**Dropping passing checks from the terminal entirely.** Rejected: "SIP is
enabled" is information, not noise — a reader wants confirmation the check ran.
The problem is one line per check, not their existence.

## Acceptance criteria

1. A run in which every check passes prints at most **two** lines per phase (the
   header and one `✓` line), and the total output is under 60 lines.
2. Every `warn` and `err` still appears in terminal output, on its own line,
   with continuation detail indented beneath it.
3. `--verbose` produces output containing at least one line per individual
   check, i.e. no fewer lines than the current implementation.
4. Piped output contains no ANSI escape sequences. (Existing CI check; must
   still hold.)
5. `--json > report.json` yields a file containing only valid JSON, with the
   same schema as before this spec. (Existing CI check.)
6. The log file contains one line per check regardless of terminal verbosity —
   collapsing is a terminal-only behaviour.
7. Finding counts in the summary equal the counts of `[WARN]` and `[ERROR]`
   lines in the log. Collapsing must not change the tally.
8. Phase elapsed time appears on every phase header and is monotonically
   non-negative.
9. A `warn` emitted before its phase completes is visible in terminal output
   even if the run is killed before `phase_end`.
10. Every existing test in `tests/test-config.sh` passes unmodified.

## Constraints in play

**bash 3.2.** No associative arrays for the per-phase buffer. Deriving the
buffer from the log file sidesteps this — no data structure is needed.

**`set -euo pipefail`.** `phase_end` greps the log for this phase's lines, and
grep matching nothing is the ordinary case for a phase with no findings. Wrap
it: `| { grep … || true; } |`. This has shipped as a real bug before.

**Read-only modes stay read-only.** Phase timing uses `date +%s`, no new writes.

## Open questions

- Whether `--verbose` should also un-collapse the summary table into the current
  flat `unresolved:` list. Leaning no: the table is strictly more information.
- Whether to right-align phase timing to a fixed column or to terminal width.
  Fixed is more predictable when output is captured; `tput cols` is unavailable
  when stdout is not a TTY, which is exactly when captures happen. Leaning
  fixed at 72.
