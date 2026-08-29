# 0003 — Agent configuration audit phase

| | |
|---|---|
| **Status** | Draft |
| **Threat model layer** | Layer 3 — Source allowlisting, extended to agent tool sources. New threat class; SECURITY.md needs a section. |
| **Breaking** | No. New phase, skipped entirely when no agent configs are present. |

## Problem

This tool verifies that the binaries on a machine came from where they claim to
have come from. It says nothing about what is permitted to invoke them.

An AI coding agent with shell access is a process that runs arbitrary commands as
the user, driven by text from a model, sometimes with that text influenced by
content the agent fetched from the internet. The configuration that bounds it —
which commands are allowed without a prompt, which MCP servers are trusted,
whether credentials are stored in plaintext beside the config — is now part of
the machine's attack surface, and no part of it is checked.

The two halves are the same problem. Verifying that `/opt/homebrew/bin/go` has
valid Sigstore provenance is worth doing *because* something invokes it; if an
agent is configured to invoke anything at all without asking, the provenance of
individual binaries is the less interesting half of the risk.

### The gap this fills

There are a lot of tools that scan agent configurations. NVIDIA SkillSpector,
Snyk Agent Scan, Cisco mcp-scanner, Tencent AI-Infra-Guard, AgentShield, Medusa
and others all read `.claude/`, MCP manifests, and skill files looking for
malicious content and misconfiguration.

None of them verify the host. Not one checks Homebrew tap trust, Sigstore
provenance on installed binaries, SHA drift between runs, or boot integrity.
They scan artefacts; this tool scans the machine.

So this phase is deliberately *not* an attempt to compete on artefact scanning.
It is the smaller, complementary half: enough agent-configuration checking to
answer the question the host-integrity checks raise on their own —
**this machine's binaries are verified; what is allowed to run them?**

Where a dedicated scanner does something better, this phase should say so rather
than reimplement it. Detecting prompt injection in a skill file is out of scope
and always will be.

## Goals

- Discover agent configurations for the tools actually installed, without being
  told where they are.
- Report configurations that grant broad or unbounded capability, credentials
  stored in plaintext, and tool sources that cannot be pinned or verified.
- Cite an authority for every finding — the MCP security specification, the
  vendor's own settings documentation, or SECURITY.md.
- Degrade to nothing when no agent is installed. A machine with no agents must
  not gain a phase that prints warnings about their absence.

## Non-goals

- **Prompt-injection detection in skills, prompts, or `CLAUDE.md`.** This is
  static analysis of natural language and it is what the dedicated scanners
  exist for. Out of scope permanently, not temporarily.
- **Scanning MCP server source code.** The tool checks how a server is
  *configured and sourced*, not what it does. Auditing the code behind
  `mongodb-mcp-server` is a different tool's job.
- **Reachability or taint analysis.** No.
- **Blocking or remediating automatically.** Every finding names a fix; none
  applies it. Rewriting a user's agent permissions without being asked is the
  behaviour of malware.
- **Judging whether a given allow-rule is correct for its owner.** `curl *`
  being allow-listed is a finding worth surfacing; whether it is acceptable is
  the user's call, expressed by suppressing the rule in config.

## Design

### Discovery

Agent configurations are found by probing known paths, not by walking the home
directory. A recursive search would be slow, would read files the user has not
consented to have read, and would produce findings about repositories the user
merely has checked out.

Probed locations, each skipped silently when absent:

| Tool | Paths |
|---|---|
| Claude Code | `~/.claude/settings.json`, `~/.claude/settings.local.json`, `~/.claude/.mcp.json` |
| Kiro | `~/.kiro/settings/mcp.json`, `~/.kiro/settings/permissions.yaml`, `~/.kiro/settings/cli.json` |
| Cursor | `~/.cursor/mcp.json` |
| Amazon Q | `~/.aws/amazonq/mcp.json` |
| VS Code | `~/Library/Application Support/Code/User/mcp.json` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |
| Gemini CLI | `~/.gemini/settings.json` |

The list lives in `config/agent-config-paths.example` so a user can add a client
this spec has not heard of, consistent with every other list in the tool.

**Project-scoped configs are not probed.** A `.mcp.json` in a repository is
found only if the user passes `--agent-scan-path`. Rationale: the tool audits
the machine, and a checked-out repository is data, not configuration. Scanning
every clone would generate findings about other people's projects.

### Rule categories

Each rule has a stable ID, a severity, a remediation, and a citation. The
catalog format is [0004](0004-rule-catalog.md); the categories are:

**`mcp.*` — MCP server configuration**

| Rule | Detects | Why |
|---|---|---|
| `mcp.secret-plaintext` | `env` value that is a literal, under a key matching `token\|key\|secret\|password\|credential` | Any process reading the file reads the credential. These files get committed to dotfile repos. |
| `mcp.tls-disabled` | `NODE_TLS_REJECT_UNAUTHORIZED=0`, `PYTHONHTTPSVERIFY=0`, `--insecure`, `--no-verify-ssl` in args | Removes the transport guarantee under Layer 1. A common workaround for a TLS-inspecting corporate proxy that outlives its reason. |
| `mcp.unpinned-package` | `npx -y <pkg>` or `uvx <pkg>` with no version, or `@latest` | A floating tag is a remote-code-execution path that changes without review. The same objection SECURITY.md already raises against `npm update -g`. |
| `mcp.plaintext-transport` | `url` beginning `http://` and not loopback | MCP spec requires HTTPS outside loopback. |
| `mcp.auto-approve` | `autoApprove`, `alwaysAllow`, `trustAllTools` present and non-empty | Removes per-tool consent, which the MCP spec names as the mitigation for local server compromise. |
| `mcp.wildcard-scope` | `oauth.scopes` containing `*`, `all`, `full-access` | MCP spec, scope minimisation: broad scopes widen the blast radius of a stolen token. |
| `mcp.command-not-absolute` | `command` that is a bare name resolved via `PATH` | PATH-order dependent. Pairs with the existing world-writable PATH check — that check finds the hijack vector, this one finds what would be hijacked. |
| `mcp.whitespace-in-value` | Leading or trailing whitespace in `command`, `url`, `args`, `env`, `headers` | Claude Code warns about this because a pasted token with a trailing newline fails in a way that is hard to diagnose. |

**`agent.*` — client settings**

| Rule | Detects | Why |
|---|---|---|
| `agent.permission-bypass` | `permissions.defaultMode` of `bypassPermissions`, or `skipDangerousModePermissionPrompt` / `skipAutoPermissionPrompt` true | Disables the consent model the vendor's own security documentation describes as the primary control. |
| `agent.hooks-disabled` | `disableAllHooks` true | Hooks are frequently the user's own guardrails. Disabling them silently removes defences the user believes are active. |
| `agent.sandbox-weakened` | `sandbox.enabled` false, or any of `allowUnsandboxedCommands`, `enableWeakerNetworkIsolation`, `enableWeakerNestedSandbox`, `ignoreViolations`, `credentials.allowPlaintextInject`, `filesystem.disabled`, `network.allowAllUnixSockets` | Each is a documented escape from the isolation boundary. |
| `agent.auto-trust-project-mcp` | `enableAllProjectMcpServers` or `allowAllClaudeAiMcps` true | A cloned repository's MCP servers start without a prompt. |
| `agent.helper-command` | `apiKeyHelper`, `policyHelper.path`, `otelHeadersHelper` set | Arbitrary shell executed on every session start. Legitimate and common; worth knowing it exists. Informational unless the target is group- or world-writable, which is an error. |
| `agent.untrusted-marketplace` | `extraKnownMarketplaces` entries, absent `strictKnownMarketplaces` | Third-party plugin source. Same reasoning as the Homebrew tap allowlist: a plugin marketplace can shadow trusted content. |
| `agent.gitignore-ignored` | `respectGitignore` false | The agent may read files excluded from version control, which is where secrets are kept. |
| `agent.secret-in-env` | Literal credential in the client's own `env` block | Same as `mcp.secret-plaintext`, different file. |

**`shell.*` — permission rule analysis**

| Rule | Detects | Why |
|---|---|---|
| `shell.arbitrary-exec` | Allow-rule matching an interpreter with a wildcard argument: `python3 *`, `node *`, `bash *`, `sh *`, `ruby *`, `perl *`, `uv run *` | An allow-rule for an interpreter is an allow-rule for every command, expressed indirectly. The narrow-looking rule has unbounded effect. |
| `shell.unrestricted-egress` | Allow-rule matching `curl *`, `wget *`, `nc *`, or `ssh *` | Grants a path off the machine for anything the agent can read. This is the exfiltration half of a prompt-injection chain. |
| `shell.command-wrapper` | Allow-rule matching a construct that can prefix any command: `for *`, `while *`, `env *`, `xargs *`, `eval *` | Wraps arbitrary execution in a rule that reads as a loop. |
| `shell.allow-deny-imbalance` | Allow-rule count exceeding deny-rule count by more than a configurable factor (default 5) | Not a vulnerability. A shape worth seeing, because a permission file grows by adding allows one prompt at a time and nobody ever revisits it. Informational. |
| `shell.deny-shadowed` | A deny pattern that a broader allow pattern in the same capability would satisfy first, given the client's documented precedence | A deny rule the user believes is protecting them that never fires. |

`shell.deny-shadowed` is the only rule requiring precedence modelling, and
precedence differs per client. It is specified last and may be deferred; the
others are string and structure matching.

### Severity and the existing gate

The tool has three levels — `ok`, `warn`, `err` — and `--fail-on` gates on them.
This phase does not introduce a parallel severity scheme.

Rules carry a severity in the catalog that maps to those levels:

| Catalog severity | Emitted as | Rationale |
|---|---|---|
| `error` | `err` | Credential exposure, disabled transport security, disabled consent. Things with no legitimate reading. |
| `warning` | `warn` | Broad capability, unpinned sources, weakened isolation. Frequently deliberate. |
| `info` | `sec` | Shape observations. Counted as a passing check, not a finding, so `--fail-on=warn` does not trip on them. |

Emitting `info` findings as `sec` is the load-bearing decision here. A rule like
`shell.allow-deny-imbalance` is genuinely useful and would be actively harmful
as a warning, because it fires on every well-used config and would train the
reader to ignore warnings. This is the false-positive discipline from
CONTRIBUTING.md applied before writing the check rather than after shipping it.

### Suppression

A user disagreeing with a rule suppresses it in
`~/.config/update-toolchain/agent-rules`:

```
# Suppress a rule everywhere
-shell.unrestricted-egress

# Suppress for one subject
-mcp.unpinned-package:internal-db-staging

# Downgrade rather than suppress
~mcp.auto-approve
```

Prefix `-` suppresses, `~` downgrades one level. Same newline-delimited,
parsed-never-sourced format as every other list, loaded by the existing
`load_list`.

Suppressions are reported in the summary as a count: `3 rules suppressed by
config`. A suppression that has become invisible is a suppression nobody
revisits.

### Phase placement

New phase, immediately after boot integrity and before the `--audit` early exit,
because it is a security check rather than an update step. `PHASE_TOTAL`
increments to 18.

The phase prints nothing and is not counted when no agent configuration is
found on the machine.

### Dependencies

Parsing JSON needs a parser. `python3` is present on every supported macOS and
is already used for the deprecated-formula check and the ollama version lookup,
so it is the parser. `jq` is not assumed.

YAML — Kiro's `permissions.yaml` — is the awkward case. Pulling in a YAML
library would add a dependency for one file. The rules that matter for that file
(allow patterns, deny patterns, counts) are extractable with the same
`sed`/`grep` discipline the config loader already uses, and a malformed file
should produce "could not parse, skipping" rather than a crash. Structural YAML
parsing is explicitly not attempted.

## Acceptance criteria

1. On a machine with no agent configuration at any probed path, the phase emits
   no output, no findings, and does not appear in the phase count.
2. Every rule that fires names: the rule ID, the file, the specific key or
   pattern, and a remediation. A finding without a remediation is a bug.
3. No secret value appears in any output stream — terminal, log, JSON, or
   report. Credential findings emit the key name and the value's character
   count. Verified by a test that plants a sentinel string in a fixture and
   greps every output for it.
4. A malformed or unparseable config produces one `warn` naming the file, and
   the phase continues to the next file.
5. Suppression entries in `agent-rules` remove the corresponding findings, and
   the count of suppressed rules appears in the summary.
6. `info`-severity rules are emitted as `sec` and do not trip `--fail-on=warn`.
7. The phase performs no network requests and writes nothing outside
   `${LOG_DIR}`.
8. The phase adds under two seconds on a machine with fewer than 50 configured
   MCP servers.
9. `--dry` and `--audit` run the phase identically to a full run, since it is
   read-only by nature.
10. Fixture-based tests cover each rule with one config that triggers it and one
    that does not. Fixtures live in `tests/fixtures/agent-configs/`.
11. `python3` absent produces one `warn` and skips JSON-derived rules, rather
    than failing the run.

## Reference material

- [MCP Security Best Practices (2025-06-18)](https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices)
  — the authority for `mcp.*`. Names confused deputy, token passthrough, SSRF,
  session hijacking, local server compromise, OAuth URL validation, stdio
  privilege escalation, and scope minimisation. Each `mcp.*` rule cites a
  section.
- Claude Code settings reference — the enumerated key space for `agent.*`.
- Claude Code permissions documentation — rule syntax and precedence, needed for
  `shell.deny-shadowed`.

## Validation against a real machine

The rule set was drafted against a working developer machine with 16 configured
MCP servers across four clients. It found:

- 9 plaintext credentials across 6 servers, in a file whose sibling
  `permissions.yaml` explicitly denies reading `.aws/credentials` and `*.pem`
- 1 server with TLS verification disabled
- 8 servers on floating `npx -y` tags
- 6 servers with `autoApprove` set
- Allow-rules for `python3 *` and `curl *` in the same permission file — an
  arbitrary-execution primitive and an egress primitive, adjacent
- 18 allow rules against 3 deny rules
- A third-party plugin marketplace with no `strictKnownMarketplaces`

Recorded because it settles the question the false-positive rule demands be
asked before writing a check: do these rules fire on real configurations for
real reasons. They do, and the machine belonged to someone who had already
thought about the problem enough to write a deny-list.

## Open questions

- Whether `mcp.command-not-absolute` is worth its false-positive rate. `npx`,
  `uvx`, and `docker` are all bare names by convention and flagging them
  produces noise on nearly every config. Options: informational only, or limit
  the rule to commands not on a known-launcher list.
- Whether to detect that a config file is inside a git repository and warn
  separately about credentials in a tracked file. Higher-signal than
  `mcp.secret-plaintext` alone, but requires running `git` from the audit path.
- Whether `agent.helper-command` should verify the target's provenance the way
  `codesign-targets` does for binaries. The helper is arbitrary code running at
  every session start, so the argument for checking it is strong; the
  implementation overlaps with Layer 6 and may belong there instead.
