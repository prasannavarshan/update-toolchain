# Security Model — `update-toolchain`

This document explains the threat model, attack surfaces, and mitigations built
into `update-toolchain`. Read this before running the script on a new machine
or adding new packages to the update list.

---

## Threat Model

### What we are defending against

| Threat | Category | Likelihood | Impact |
|--------|----------|-----------|--------|
| Malicious package injected into a package registry (npm, PyPI, Homebrew) | Supply-chain | Medium | Critical |
| Compromised third-party Homebrew tap | Supply-chain | Medium | High |
| DNS/BGP hijack redirecting update traffic | Network MITM | Low | Critical |
| Typosquatting (e.g. `aws-cdk` vs `awss-cdk`) | Supply-chain | Medium | High |
| Malicious `postinstall`/`preinstall` scripts in npm packages | Supply-chain | High | High |
| PATH hijack via world-writable directory | Local privilege | Low | High |
| Binary replacement after update (compromised local system) | Post-compromise | Low | High |
| macOS SIP/Gatekeeper disabled (kernel-level tampering) | Local privilege | Low | Critical |

### What we are NOT defending against

- A fully compromised macOS kernel or firmware (out of scope for a shell script)
- Compromised Apple-signed macOS updates (trust Apple's PKI)
- Homebrew's own infrastructure being compromised (mitigated by SHA recording)

---

## Mitigations by Layer

### Layer 1 — Transport Security

All update channels use **TLS 1.2+** enforced by the respective tools:

| Tool | Update channel | TLS enforced by |
|------|---------------|-----------------|
| Homebrew | `brew update` → GitHub CDN | macOS SecureTransport |
| uv | `uv self update` → GitHub Releases | uv's built-in TLS client |
| rustup | `rustup update` → static.rust-lang.org | rustup's built-in TLS |
| npm | registry.npmjs.org | Node.js TLS stack |
| pnpm | `pnpm self-update` → GitHub Releases | Node.js TLS stack |
| macOS | `softwareupdate` → Apple CDN | Apple-signed, code-verified |

### Layer 2 — Cryptographic Verification

| Tool | Verification method |
|------|-------------------|
| Homebrew bottles | SHA256 checksum embedded in formula, verified before install |
| uv | [Sigstore / cosign](https://github.com/astral-sh/uv#installation) — binary signatures verified automatically |
| rustup components | SHA256 manifest signed by the Rust project, verified by rustup |
| npm packages | `npm audit` cross-checks against GitHub Advisory DB + NIST NVD |
| macOS updates | Apple code-signing (Developer ID + notarization) |

### Layer 3 — Source Allowlisting

#### Homebrew taps

The script enforces an **explicit allowlist** of trusted third-party taps, read from
`~/.config/update-toolchain/allowed-taps`. Official `Homebrew/*` taps are trusted by
verified git remote URL rather than by name, so a local tap masquerading as
`homebrew/core` while pointing elsewhere is rejected.
Any tap not on the list causes the script to **abort** before making any changes.

**Why this matters:** A compromised or malicious tap can shadow official formulae
(e.g., a tap named `evil/tap` with a formula called `node` that runs a backdoor).
Homebrew resolves formula names in tap order, so an untrusted tap can silently
override official packages.

**How to add a new tap:**
1. Verify the tap's GitHub org is the official vendor
2. Check the tap's formula files for suspicious `postinstall` hooks
3. Add it to `~/.config/update-toolchain/allowed-taps` with a comment explaining why

#### npm packages

The script uses an **explicit pinned list** (`~/.config/update-toolchain/npm-pinned`). It never runs
`npm update -g` or `npm install -g` without a specific package name.

All npm installs use `--ignore-scripts` to **prevent postinstall/preinstall
script execution** — the most common npm supply-chain attack vector
(e.g., the `event-stream` incident, `ua-parser-js` hijack).

> ⚠️ Note: `--ignore-scripts` may break packages that require a native build
> step (e.g., packages with C++ addons). If a package fails to work after
> install, check if it legitimately needs build scripts before re-enabling them.

### Layer 4 — System Integrity Checks

The script verifies the following before making any changes:

| Check | What it detects |
|-------|----------------|
| Homebrew remote origin | Detects if Homebrew itself has been replaced with a fork |
| SIP status (`csrutil`) | Warns if System Integrity Protection is disabled |
| Gatekeeper status (`spctl`) | Warns if unsigned app execution is allowed |
| World-writable PATH dirs | Detects PATH hijack vectors |

### Layer 5 — SHA256 Audit Trail

After every run, the script appends a timestamped SHA256 record of all key
binaries to `~/.local/share/update-toolchain/binary-shas.txt`.

**How to use this:**
```bash
# Compare today's hashes to last week's
grep "brew" ~/.local/share/update-toolchain/binary-shas.txt | tail -10

# Alert on unexpected changes between two consecutive runs
diff \
  <(grep "2026-03-30" ~/.local/share/update-toolchain/binary-shas.txt) \
  <(grep "2026-03-31" ~/.local/share/update-toolchain/binary-shas.txt)
```

If a binary's SHA changes without a corresponding update in the log, that is a
**red flag** indicating possible binary replacement.

---

## Operational Procedures

### Before running on a new machine

1. Verify the script itself:
   ```bash
   # Check the script hasn't been tampered with since you last reviewed it
   shasum -a 256 update-toolchain
   # Compare to the hash in your git history
   git log --oneline update-toolchain
   git show HEAD:update-toolchain | shasum -a 256
   ```

2. Run in audit mode first:
   ```bash
   update-toolchain --audit
   ```

3. Review the tap allowlist matches your actual installed taps:
   ```bash
   brew tap
   ```

### Adding a new package

#### Homebrew formula/cask
- Verify it comes from `homebrew/core` or `homebrew/cask` (official)
- If it requires a third-party tap, add it to `allowed-taps` with justification

#### npm global
- Add to the `npm-pinned` config file only
- Check the package's npm page for download counts, maintainer history, and recent publish activity
- Run `npm audit` after adding

#### Homebrew tap
- Verify the GitHub org is the official vendor (check their website)
- Review the tap's formula files for `postinstall` hooks
- Add to the `allowed-taps` config file with a comment

### Responding to a security incident

If you suspect a package was compromised:

1. **Stop the script immediately** (Ctrl+C)
2. Check the SHA log for unexpected changes:
   ```bash
   tail -50 ~/.local/share/update-toolchain/binary-shas.txt
   ```
3. Check recently installed/updated packages:
   ```bash
   brew list --versions | sort -k2 -t@ | tail -20
   npm list -g --depth=0
   ```
4. Revoke any credentials that may have been exposed (API keys, SSH keys, AWS credentials)
5. Consider restoring from a known-good Time Machine snapshot

---

## Configuration as data, not code

Every allowlist is a newline-delimited text file under
`${XDG_CONFIG_HOME:-~/.config}/update-toolchain/`, falling back to the bundled
`config/*.example`. The loader parses these files with `sed`/`grep`; it never
sources them.

This is deliberate. A sourced shell config would mean anyone who can write your
config file can execute arbitrary code as you — turning the configuration
surface of a security tool into a privilege-escalation path. Parsed data has no
such property.

## Known Limitations

| Limitation | Mitigation |
|-----------|-----------|
| `--ignore-scripts` may break some npm packages | Test after install; re-enable only if the build script is audited |
| SHA recording doesn't detect in-memory attacks | Complemented by SIP + Gatekeeper |
| Homebrew bottle SHA is verified by Homebrew, not independently | Trust Homebrew's PKI; monitor [Homebrew security advisories](https://github.com/Homebrew/brew/security/advisories) |
| `pnpm self-update` doesn't have Sigstore verification yet | Mitigated by TLS + GitHub Releases source |
| macOS updates are listed but not auto-installed | Intentional — auto-installing OS updates can break dev tooling |

---

## Why Bash (and when to consider rewriting)

The current implementation is **intentionally bash** because:

- Zero runtime dependencies (no Python, Node, or Go required to run the updater itself)
- Runs before any language runtime is guaranteed to be healthy
- Transparent — every command is visible and auditable line-by-line
- No supply-chain risk from the updater's own dependencies

**Consider rewriting in Go or Rust if:**
- You need parallel updates (Go's goroutines or Rust's async make this clean)
- You want typed configuration (TOML/YAML allowlists instead of bash arrays)
- You want structured JSON logs for ingestion into a SIEM
- The script grows beyond ~300 lines and becomes hard to maintain

A Go rewrite would look like: a single statically-compiled binary with no
external dependencies, embedded allowlists, and `go-update` style self-verification.

---

## References

- [SLSA Supply Chain Levels](https://slsa.dev/)
- [npm security best practices](https://docs.npmjs.com/threats-and-mitigations)
- [Homebrew security policy](https://github.com/Homebrew/brew/blob/master/SECURITY.md)
- [uv Sigstore verification](https://github.com/astral-sh/uv#installation)
- [rustup security model](https://rust-lang.github.io/rustup/security.html)
- [macOS SIP overview](https://support.apple.com/en-us/102149)

---

## Layer 6 — Post-Update Supply-Chain Verification (Section 15)

Added 2026-08-21. Addresses 8 gaps identified via industry best-practice gap analysis
against SLSA v1.0/v1.2, NIST SP 800-218 (SSDF), and CISA Secure Software Development guidance.

### What Layer 6 Adds

| Check | What it verifies | Industry standard |
|-------|-----------------|-------------------|
| 15a. Brew Sigstore provenance | SLSA L3 attestation on critical Homebrew bottles | SLSA v1.0 consumer verification |
| 15b. npm `audit signatures` | Sigstore provenance on npm global packages | npm Trusted Publishing (GA Oct 2023) |
| 15c. GitHub attestation verify | SLSA provenance for GitHub Releases binaries | GitHub Artifact Attestations (GA 2024) |
| 15d. SBOM + grype scan | Embedded dependency vulnerabilities in compiled binaries | NIST SSDF PS.3, SBOM mandates (EO 14028) |
| 15e. macOS codesign | Apple code signature validity on signed binaries | macOS Endpoint Security |
| 15f. Binary SHA diff alerting | Unexplained binary mutations between runs | NIST SSDF PS.1, file integrity monitoring |
| 15g. govulncheck | Go stdlib/module vulns in compiled Go binaries | Go security team recommendation |
| 15h. cargo audit | RustSec advisory DB scan for Rust dependencies | Mozilla supply-chain audit methodology |

### Gap Analysis Summary

| # | Gap (pre-fix) | Risk | Fix |
|---|---------------|------|-----|
| 1 | No independent provenance verification | Medium | `brew verify` on critical formulae |
| 2 | `npm audit` ≠ `npm audit signatures` | Medium | Added signature provenance check |
| 3 | GitHub fallback downloads not attested | High | `gh attestation verify` before install |
| 4 | No SBOM or binary-level vuln scan | Medium | syft → grype pipeline |
| 5 | No codesign verification on signed binaries | Low | codesign -v on commercial tools |
| 6 | SHA recorded but never compared | High | Automated diff with unexplained-change alerting |
| 7 | Go binaries (trivy, gh, etc.) never scanned | Medium | govulncheck -mode=binary |
| 8 | Cargo binaries never audited | Low | cargo audit against RustSec DB |

### SLSA Compliance Level (this script)

| SLSA Requirement | Our Implementation | Level |
|-----------------|-------------------|-------|
| Checksums at install time | brew SHA256, npm SRI, go.sum | L1 ✓ |
| Signed provenance verification | brew verify (Sigstore), npm audit signatures, gh attestation verify | L2/L3 ✓ |
| Post-install integrity monitoring | SHA diff alerting with unexplained-change detection | L2 ✓ |
| Dependency vulnerability scanning | pip-audit, npm audit, govulncheck, cargo audit, grype | Beyond SLSA (vuln mgmt) |
| Build platform hardening | Delegated to upstream (Homebrew, GitHub Actions, PyPI) | L3 (inherited) |

### Dependencies Required for Full Verification

```bash
# Core (already in brew-tools registry)
brew install syft grype cosign

# Go tooling
go install golang.org/x/vuln/cmd/govulncheck@latest

# Rust tooling
cargo install cargo-audit

# These are optional — the script degrades gracefully if missing
```

### Known Limitations of Layer 6

| Limitation | Mitigation |
|-----------|-----------|
| `brew verify` coverage depends on Homebrew publishing attestations | Falls back to SHA comparison |
| Only ~7% of npm packages have provenance (ecosystem-wide) | `npm audit signatures` still checks registry ECDSA signatures |
| `govulncheck -mode=binary` only works on unstripped Go binaries | Most brew-installed Go tools retain debug info |
| `gh attestation verify` requires the project to publish attestations | Warns and continues if unavailable |
| syft can't always extract SBOM from static Rust/C binaries | Best-effort; Go binaries have best coverage |
| codesign verification is mostly useful for commercial/Apple-signed tools | Homebrew CLIs are typically unsigned |

---

## References (updated)

- [SLSA Supply Chain Levels](https://slsa.dev/)
- [SLSA v1.0 — Verification specification](https://slsa.dev/spec/v1.0/verifying-artifacts)
- [NIST SP 800-218 (SSDF)](https://csrc.nist.gov/publications/detail/sp/800-218/final)
- [CISA Secure Software Development Attestation](https://www.cisa.gov/secure-software-attestation-form)
- [npm provenance documentation](https://docs.npmjs.com/generating-provenance-statements)
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
- [Homebrew Sigstore attestations](https://github.com/Homebrew/brew/issues/17019)
- [govulncheck binary mode](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
- [RustSec Advisory Database](https://rustsec.org/)
- [Anchore syft + grype](https://github.com/anchore/syft)
- [Homebrew security policy](https://github.com/Homebrew/brew/blob/master/SECURITY.md)
- [uv Sigstore verification](https://github.com/astral-sh/uv#installation)
- [rustup security model](https://rust-lang.github.io/rustup/security.html)
- [macOS SIP overview](https://support.apple.com/en-us/102149)
