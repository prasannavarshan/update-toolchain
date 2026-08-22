# Changelog

## v0.3.0

### Added
- `--json`: a machine-readable report on stdout with all progress moved to
  stderr, so `--json > report.json` yields a file containing only JSON. Counts
  and findings are suitable for a dashboard or an alert.
- An end-of-run summary with real counts, a verdict, and every unresolved
  warning and error gathered in one place.
- `[n/16]` phase markers. No animation and no carriage returns, so a redirected
  run still reads back as a clean list.
- `--color=auto|always|never`, honouring [`NO_COLOR`](https://no-color.org).

### Fixed
- **The world-writable PATH check was wrong twice over** and fired on correctly
  configured machines. It matched any two `w` characters anywhere, which flags
  every group-writable directory — Homebrew's own normal layout — and its
  positional test was off by one, reading other-*read* instead of other-write.
  A security check that fires on a healthy system teaches people to ignore it.
  Now an extracted, tested predicate.
- Output was coloured unconditionally, so any pipe or CI log collected escape
  codes. Colour is now off unless stdout is a terminal. Every status also
  carries a text label, so nothing is conveyed by colour alone.
- `--audit` exited before reaching the end of the script, so neither the summary
  nor the JSON report ran in one of the two read-only modes. All terminal paths
  now route through one function, `die` included.
- Finding counts were inflated by continuation lines: one untrusted tap was
  reported as three errors, one `brew doctor` warning as ten. Remediation text
  and captured output are now `[DETAIL]` — shown and logged, never tallied.

## v0.2.0

### Changed
- Install instructions are a single line, and the required `brew trust` step is
  explained rather than just listed. Homebrew refuses to load formulae from
  untrusted third-party taps and a tap cannot waive that from its own side, so
  an unexplained `trust` command in a security tool's README reads like a red
  flag. Also documents trusting the single formula instead of the whole tap.
- The Homebrew formula moved to the tap repo
  ([prasannavarshan/homebrew-tap](https://github.com/prasannavarshan/homebrew-tap)),
  so there is one copy to update per release rather than two.

## v0.1.0

First public extraction from a private dotfiles repo. Changes made during
extraction, beyond moving files:

### Added
- Config files for every allowlist, resolved from
  `$UPDATE_TOOLCHAIN_CONFIG` → `${XDG_CONFIG_HOME:-~/.config}/update-toolchain/`
  → bundled `config/*.example`. Previously these were hardcoded arrays, which
  meant every user would have inherited one machine's personal toolset.
- Config files are **parsed, never sourced**, so a config file cannot execute
  code. Covered by a test that fails if the loader ever gains that ability.
- `tests/test-config.sh` — 12 checks, no dependencies beyond bash 3.2.
- Apache-2.0 license.

### Fixed
- `--dry` and `--audit` no longer prompt for sudo. Sudo was primed
  unconditionally at startup, before any mode check, so both read-only modes
  died immediately in any non-interactive context — CI, containers, or a first
  evaluation by a new user. Two further ungated `sudo -v` refreshes deeper in
  the script had the same effect mid-run.
- Untrusted Homebrew taps now warn instead of aborting when running `--dry` or
  `--audit`. Aborting on the first finding suppressed the rest of the audit,
  which defeats the purpose of an audit mode.
- Official `Homebrew/*` taps are trusted by **verified git remote URL** rather
  than by name. This is stricter than the previous name allowlist — a local tap
  named `homebrew/core` whose remote points elsewhere is now rejected — and it
  removes a class of false positive, such as the deprecated but genuine
  `homebrew/brew-vulns` tap.
- Dry-run output no longer splits commands across lines. The script sets
  `IFS=$'\n\t'`, so `$*` in the dry-run branch joined argv with newlines and
  printed `brew update` as two lines.
- Homebrew paths derive from `brew --prefix` instead of a hardcoded
  `/opt/homebrew`, so code-signature checks and SBOM generation work on Intel
  Macs as well as Apple Silicon. Config files may use `${BREW_PREFIX}`.

### Changed
- Corporate-proxy handling generalised from Zscaler-specific naming to
  restricted-network handling, since the same blocking behaviour appears with
  Netskope, Palo Alto and others.
- Installed command renamed from `update-toolchain.sh` to `update-toolchain`.
