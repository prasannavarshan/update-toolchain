# 0004 — Rule catalog format and IDs

| | |
|---|---|
| **Status** | Draft |
| **Threat model layer** | Cross-cutting. Gives every finding an identity. |
| **Breaking** | No, but it adds a field to `--json`. Consumers reading positionally would break; consumers reading by key would not. |

## Problem

Findings are currently strings. `"UNTRUSTED TAP DETECTED: 'x'"` is the whole
identity of that finding — there is no code to suppress, no severity separate
from the log level it was emitted at, no remediation field, and no way for a
consumer to group two runs' findings as the same issue.

Three specs need this. [0001](0001-terminal-output.md) wants a `CHECK` column.
[0002](0002-reports.md) needs remediation and threat-citation text as its
payload, not as decoration. [0003](0003-agentic-hygiene.md) needs suppression by
identifier and a severity that is decoupled from the emitted log level.

Building it three times in three different shapes is the failure mode this spec
prevents.

## Goals

- Every finding carries a stable identifier that survives message rewording.
- Remediation and threat citation are structured fields, not prose embedded in a
  message.
- Severity is a property of the rule, separate from the log level it produces.
- Adding a rule is adding a catalog row, not editing the emit sites.
- Existing findings gain IDs without their messages changing.

## Non-goals

- **A rule DSL or plugin system.** Rules are bash conditions in the numbered
  sections where they already live. This spec standardises how a rule *reports*,
  not how it *detects*.
- **Machine-readable rule metadata as a separate published artefact.** The
  catalog is an internal table. If it ever needs publishing, that is a later
  spec.
- **Renaming or restructuring existing checks.** They get IDs matching what they
  already do.

## Design

### ID format

```
<domain>.<rule>
```

Lowercase, hyphen-separated within each part, dot-separated between. No
version, no numeric prefix — the string is the identity, and a rule that changes
meaning enough to matter gets a new ID rather than a version bump.

Domains, one per subsystem the tool inspects:

| Domain | Covers |
|---|---|
| `brew` | Homebrew: remote origin, taps, doctor, deprecated formulae |
| `system` | SIP, Gatekeeper, PATH permissions |
| `boot` | Kexts, SSV, LaunchDaemons, firmware, FileVault |
| `npm` | Global package updates, audit, provenance signatures |
| `sha` | Binary SHA recording and drift |
| `provenance` | Sigstore, GitHub attestations, code signatures |
| `vuln` | grype, govulncheck, cargo audit, pip-audit |
| `mcp` | MCP server configuration ([0003](0003-agentic-hygiene.md)) |
| `agent` | Agent client settings ([0003](0003-agentic-hygiene.md)) |
| `shell` | Agent permission rules ([0003](0003-agentic-hygiene.md)) |
| `tool` | The tool's own failures — missing dependency, unparseable config |

Retrofitted IDs for findings that exist today:

```
brew.untrusted-tap            brew.remote-tampered
brew.doctor                   brew.deprecated-formula
system.sip-disabled           system.gatekeeper-disabled
system.path-world-writable
boot.non-apple-kext           boot.ssv-missing
boot.new-launchdaemon         boot.firmware-pending
boot.filevault-disabled
sha.unexplained-change        provenance.unverified
vuln.grype  vuln.govulncheck  vuln.cargo-audit  vuln.pip-audit
tool.missing-dependency       tool.unparseable-config
```

### Catalog location

`config/rules` — shipped, not user-editable, unlike every other file in
`config/`. It is the tool's own data.

This is the one exception to config-as-user-policy, and it needs justifying: a
user who can rewrite severity and remediation text can make a finding say the
opposite of what the check found. That is a property a security tool should not
offer. Users influence rules through `agent-rules` suppression
([0003](0003-agentic-hygiene.md)), which is additive and visible — a suppression
is reported as a count, a rewritten catalog would be silent.

Format, pipe-delimited so `load_list`'s comment and blank-line stripping applies
unchanged:

```
# id | severity | title | remediation | citation
mcp.secret-plaintext | error | Credential stored as a literal in MCP config | Move the value to the system keychain and reference it as ${VAR} | MCP: local server compromise
mcp.tls-disabled | error | TLS certificate verification disabled | Remove the variable and add the proxy CA to the trust store instead | SECURITY.md Layer 1
shell.allow-deny-imbalance | info | Allow rules greatly outnumber deny rules | Review the allow list; permission files grow one prompt at a time | —
```

Pipe rather than JSON because the loader already parses newline-delimited text
with `sed`, and because a catalog that needs `python3` to read would make the
tool's own reporting depend on an optional dependency.

Fields are fixed-arity. A remediation that has no sensible value is `—`, not
empty, so a truncated row is detectable.

### Emit sites

A new helper alongside `warn`/`err`/`sec`:

```bash
finding <rule-id> <subject> [extra-detail...]
```

It looks the rule up in the catalog, maps severity to log level, prints, and
appends a structured line to the log. Call sites become:

```bash
# before
err "UNTRUSTED TAP DETECTED: '$tap'${remote:+ → $remote}"
detail "→ Remove it:   brew untap '$tap'"
detail "→ Or trust it: echo '$tap' >> ${CONFIG_DIR}/allowed-taps"

# after
finding brew.untrusted-tap "$tap" "${remote:-no remote}"
```

Remediation text moves from the call site to the catalog, which is the point:
one place to review the wording, and the report and terminal can render it
differently without the emit site knowing.

Severity mapping is [0003](0003-agentic-hygiene.md)'s: `error`→`err`,
`warning`→`warn`, `info`→`sec`. `--fail-on` is unchanged because it counts log
levels, not catalog severities.

### Log line format

Findings gain a machine-parseable form while staying readable, since the log is
read by both the summary and a human:

```
[2026-08-25T03:40:02Z] [ERROR] [brew.untrusted-tap] example/tap — no remote
```

The existing `_tally` greps `[ERROR]` and `[WARN]` and continues to work.
Extracting the rule ID is a second field, not a new file.

### JSON addition

```json
{
  "level": "ERROR",
  "rule": "brew.untrusted-tap",
  "severity": "error",
  "subject": "example/tap",
  "title": "Untrusted Homebrew tap",
  "remediation": "brew untap it, or add it to allowed-taps",
  "citation": "SECURITY.md Layer 3",
  "message": "example/tap — no remote"
}
```

`message` and `level` keep their current meaning, so a consumer reading only
those is unaffected. Findings emitted without a catalog entry — during the
migration, or from a code path not yet converted — carry `"rule": null` and the
other fields absent, rather than blocking on total conversion.

### Migration

Incremental. `finding` and the catalog land first with `warn`/`err` still
working. Call sites convert as their sections are touched. A test asserts that
every ID referenced by a `finding` call exists in the catalog, which makes a
typo a test failure rather than a silently unlabelled finding.

No flag day. A partially-migrated tool is correct, just less uniform.

### Rejected alternatives

**Numeric IDs (`UT-0042`).** Rejected: unreadable in terminal output, and the
number carries no information the reader can use. `mcp.secret-plaintext` is
self-describing in a way `UT-0042` never becomes.

**Severity in the ID (`mcp.error.secret-plaintext`).** Rejected: severity is
adjustable by suppression config; baking it into the identity means a downgraded
rule has a different ID than the same rule at full severity.

**JSON or YAML catalog.** Rejected: introduces a parser dependency for the
tool's own reporting path. Pipe-delimited text reuses the existing loader.

## Acceptance criteria

1. Every `finding` call site references an ID present in `config/rules`;
   a test fails otherwise.
2. Every catalog row has exactly five pipe-delimited fields; a test fails
   otherwise.
3. Severity maps to log level as specified, and `--fail-on` behaviour is
   unchanged for every finding that existed before this spec.
4. `--json` findings include `rule`, `severity`, `title`, `remediation`, and
   `citation` when a catalog entry exists, and `"rule": null` when it does not.
   `level` and `message` are unchanged.
5. `_tally` counts are identical before and after migration for the same
   machine state.
6. The catalog is loaded through the existing `load_list`, i.e. it is parsed and
   never sourced. The existing config-cannot-execute-code test extends to it.
7. A missing or unreadable `config/rules` degrades to findings without metadata
   plus one `tool.missing-dependency` warning, rather than failing the run.
8. Terminal output for a converted finding is no less informative than before
   conversion — remediation still reaches the reader, via `detail`.
9. Rule IDs appear in the log in the specified position and are extractable with
   `sed`.

## Constraints in play

**Config is data, never code.** The catalog contains remediation text with shell
metacharacters — `${VAR}`, `>>`, backticks in prose. It is read and printed,
never evaluated. The existing canary test must cover `config/rules`, not only
the user-facing lists.

**bash 3.2.** No associative array for id→row. Lookup is a `grep` against the
catalog per finding. At the scale involved — tens of findings, tens of rules —
the cost is irrelevant and the alternative is unavailable.

**`set -euo pipefail`.** A catalog lookup that matches nothing is the expected
case for an unmigrated ID. Wrap it.

## Open questions

- Whether `citation` should be a URL or a short label. Labels read better in a
  terminal and do not rot; URLs are more useful in the markdown report. Possible
  answer: label in the catalog, with a separate `config/citations` mapping
  labels to URLs that the report resolves and the terminal ignores.
- Whether `subject` needs structure — for `mcp.*` it is naturally
  `server/key`, for `sha.*` it is a path. Currently a free string. Structuring it
  would help the report group findings; leaving it free is simpler and defers a
  decision that is cheap to revisit.
