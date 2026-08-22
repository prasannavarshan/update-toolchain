# Changelog

## Unreleased

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
