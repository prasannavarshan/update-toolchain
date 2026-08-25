# update-toolchain

Supply-chain hardened updater for a macOS developer toolchain.

Updating your tools is the one thing you do routinely that executes remote code
as your user, on purpose, on every machine you own. `brew upgrade` and
`npm update -g` are trusted-by-default operations, and almost nobody verifies
what they actually pulled down.

This runs the same updates with verification in front of them: Sigstore
provenance on Homebrew bottles, npm provenance signatures, SBOM generation and
vulnerability scanning, code-signature checks, and a SHA256 audit trail that
tells you when a binary changed *without* a corresponding update.

The reasoning is written up in [docs/article.md](docs/article.md); the threat
model and per-layer mitigations are in [SECURITY.md](SECURITY.md).

## Scope, honestly

**macOS only.** This is built on Homebrew, `codesign`, and `softwareupdate`.
There is no Linux path and no plan for one — a cross-platform version would be
a different program, not a flag.

It covers Homebrew (formulae + casks), global npm packages, pipx, uv, rustup,
gcloud components, and Go tools, skipping whatever isn't installed. macOS system
updates are **reported but never installed**, because they need a restart and
that should stay your decision.

## Install

```bash
brew tap prasannavarshan/tap && brew trust prasannavarshan/tap && brew install update-toolchain
```


After install, seed the config for your machine:

```bash
update-toolchain --init
```

This copies the bundled allowlist examples into `~/.config/update-toolchain/`
and appends any third-party taps already on your machine. Without this step the
first run will flag your taps (including this one) as untrusted — the tool
treats every trust decision as opt-in.

The `brew trust` step is required, not optional: current Homebrew refuses to
load a formula from an untrusted third-party tap, and only official Homebrew
repositories are trusted by default. A tap cannot waive that from its own
side — trust is granted on the installing machine, which is rather the point.

Read the formula before you grant it if you would prefer not to take it on
faith; it installs one bash script and a directory of example config. To trust
just this formula rather than the whole tap:

```bash
brew trust --formula prasannavarshan/tap/update-toolchain
```

Or run it straight from a clone — there is no build step:

```bash
git clone https://github.com/prasannavarshan/update-toolchain
./update-toolchain/bin/update-toolchain --dry
```

## Use

```bash
update-toolchain --dry     # report what would change; touches nothing
update-toolchain --audit   # security checks only, no updates
update-toolchain           # apply updates
update-toolchain --json    # machine-readable report on stdout
update-toolchain --init    # one-time: seed config for this machine
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | clean, or findings below the `--fail-on` threshold |
| `1` | findings at or above `--fail-on` |
| `2` | the tool itself could not complete |

Findings do **not** fail the run by default, so a local check reports without
returning a scary status. CI opts in:

```bash
update-toolchain --audit --fail-on=error   # exit 1 on any error
update-toolchain --audit --fail-on=warn    # exit 1 on any warning too
```

The exit code is independent of `--json`, so the report is still written when
the gate trips and a pipeline can upload it before failing.

Colour follows `--color=auto|always|never`, defaulting to auto: on only when
stdout is a terminal and [`NO_COLOR`](https://no-color.org) is unset. Redirect
to a file or a pipe and the output contains no escape codes. Every status also
carries a text label, so nothing is conveyed by colour alone.

`--json` puts the report on stdout and moves all progress output to stderr, so
`update-toolchain --json > report.json` yields a file containing only JSON.
Findings and counts are suitable for feeding a dashboard or an alert:

```json
{
  "mode": "audit",
  "counts": { "ok": 0, "warnings": 2, "errors": 1, "security_checks": 10 },
  "findings": [
    { "level": "ERROR", "message": "UNTRUSTED TAP DETECTED: ..." }
  ]
}
```

Every run ends with a summary — counts, a verdict, and the unresolved warnings
and errors gathered in one place, rather than needing a scroll back through the
output.

Start with `--dry`. Neither `--dry` nor `--audit` prompts for sudo or modifies
anything, so both are safe to run in CI or a container.

Logs and the SHA snapshot go to `~/.local/share/update-toolchain/`.

## Configuration

The security model is an allowlist, and an allowlist is inherently
per-machine — so the lists live in config files, not in the script. Nothing is
updated unless you have named it.

Resolution order for each list:

1. `$UPDATE_TOOLCHAIN_CONFIG/<name>`
2. `${XDG_CONFIG_HOME:-~/.config}/update-toolchain/<name>`
3. the bundled `config/<name>.example`, so a fresh clone runs out of the box

```bash
mkdir -p ~/.config/update-toolchain
cp config/*.example ~/.config/update-toolchain/
# then drop the .example suffix and edit for your machine
cd ~/.config/update-toolchain && for f in *.example; do mv "$f" "${f%.example}"; done
```

| List | Controls |
|---|---|
| `allowed-taps` | Third-party Homebrew taps you trust. Official `Homebrew/*` taps are trusted automatically **by verified remote URL**, so they don't need listing. |
| `npm-pinned` | The only global npm packages that get updated. `npm update -g` is never run. |
| `provenance-formulae` | Formulae whose Sigstore attestations are verified via `brew verify`. |
| `codesign-targets` | Binaries checked with `codesign -v`. `${BREW_PREFIX}` expands to your Homebrew prefix, so this works on both Apple Silicon and Intel. |
| `record-binaries` | Binaries whose SHA256 is recorded each run for drift detection. |

Format is newline-delimited text; `#` starts a comment. **Config files are
parsed, never sourced** — a config file cannot execute code. That matters for a
tool whose entire purpose is deciding what to trust.

### Restricted networks

Some corporate TLS-inspecting proxies (Zscaler, Netskope, Palo Alto) block
vendor install scripts and CDN endpoints while allowing `ghcr.io` and GitHub
releases. The restricted-network section carries fallback download paths for
tools affected by this. On a normal network it's a no-op.

## Requirements

- macOS with Homebrew
- bash 3.2 (the stock macOS bash — no upgrade needed)
- `gh` for GitHub release attestation checks; `syft`, `grype`, `cosign`,
  `govulncheck` for the SBOM and vulnerability layers. Each is optional and its
  step is skipped when absent.

## Known limitations

Read [SECURITY.md](SECURITY.md#known-limitations) before relying on this. The
short version: it verifies provenance and detects drift, but it cannot defend
against a compromised upstream that signs its artifacts correctly, and it trusts
Homebrew's own update path.

## License

Apache-2.0. See [LICENSE](LICENSE).
