# Your Developer Toolchain Is a Supply Chain Attack Surface — Here's How I Hardened Mine

*A practical guide to applying SLSA, Sigstore, and SBOM-based verification to the tools on your local machine.*

---

## The Problem Nobody Talks About

We obsess over dependency scanning in CI/CD. We pin versions in `package-lock.json`. We run Dependabot. But what about the tools that *build* your software?

Every morning, you run `brew upgrade`. npm updates your global packages. `rustup update` refreshes your Rust toolchain. Each of these is an implicit trust decision:

> *"I trust that the binary I just downloaded is exactly what the publisher built, from the source code I'd expect, without tampering in transit."*

For most developers, that trust is blind. I decided to make it explicit.

---

## Threat Model: What Can Go Wrong

| Threat | Real-World Example | Likelihood |
|--------|-------------------|-----------|
| Malicious package in registry | `event-stream` (npm, 2018), `ua-parser-js` (npm, 2021) | **High** |
| Compromised Homebrew tap | Typosquatting tap overrides official formula | Medium |
| npm postinstall script RCE | `eslint-scope` credential theft (2018) | **High** |
| Binary replaced after install | Compromised local system, PATH hijack | Low |
| DNS/BGP hijack on update channel | PyPI CDN poisoning (hypothetical) | Low |
| Dependency confusion | Internal package name claimed on public registry | Medium |

The attack surface is your entire toolchain: **compilers, linters, security scanners, CLI tools, language runtimes**. If an attacker compromises `trivy`, they can hide their own CVEs from your scans.

---

## The Architecture: 6 Defense Layers

![Supply Chain Verification Architecture](./supply-chain-architecture.excalidraw.png)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DEVELOPER WORKSTATION                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Layer 1: TRANSPORT SECURITY                                        │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  All channels: TLS 1.2+ (brew, npm, PyPI, crates.io, Go)    │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│  Layer 2: CRYPTOGRAPHIC VERIFICATION                                │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  brew: SHA256 bottles    │  uv: Sigstore cosign              │  │
│  │  rustup: signed manifest │  npm: ECDSA registry sigs         │  │
│  │  macOS: Apple code-sign  │  Go: sum.golang.org               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│  Layer 3: SOURCE ALLOWLISTING                                       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Homebrew tap allowlist (BLOCK on untrusted)                  │  │
│  │  npm pinned package list + --ignore-scripts                   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│  Layer 4: SYSTEM INTEGRITY                                          │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  SIP enabled │ Gatekeeper enabled │ No world-writable PATH   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│  Layer 5: AUDIT TRAIL                                               │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  SHA256 pre/post snapshot │ Timestamped log │ Diff alerting   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│  Layer 6: SUPPLY-CHAIN VERIFICATION (post-update)                   │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  ┌─────────────┐ ┌───────────────┐ ┌─────────────────────┐  │  │
│  │  │ brew verify │ │ npm audit sig │ │ gh attestation      │  │  │
│  │  │ (Sigstore)  │ │ (provenance)  │ │ verify (SLSA L3)    │  │  │
│  │  └─────────────┘ └───────────────┘ └─────────────────────┘  │  │
│  │  ┌─────────────┐ ┌───────────────┐ ┌─────────────────────┐  │  │
│  │  │ syft→grype  │ │ govulncheck   │ │ cargo audit         │  │  │
│  │  │ (SBOM+CVE)  │ │ (-mode=binary)│ │ (RustSec DB)        │  │  │
│  │  └─────────────┘ └───────────────┘ └─────────────────────┘  │  │
│  │  ┌─────────────┐ ┌───────────────┐                          │  │
│  │  │ codesign -v │ │ SHA diff alert│                          │  │
│  │  │ (macOS sig) │ │ (tampering)   │                          │  │
│  │  └─────────────┘ └───────────────┘                          │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## The Gap Analysis: Industry vs. Reality

I benchmarked my existing toolchain updater against SLSA v1.0, NIST SP 800-218 (SSDF), and CISA's Secure Software Development guidance. Here's what I found:

### What Most Developers Have (SLSA L1)

- ✅ Lock files with checksums (`package-lock.json`, `Cargo.lock`, `go.sum`)
- ✅ TLS on all download channels
- ✅ Package manager verifies checksums at install time

### What's Missing (SLSA L2/L3)

| Gap | Risk | What's actually needed |
|-----|------|----------------------|
| No independent provenance verification | Medium | Don't just trust the package manager's internal check — verify Sigstore attestations yourself |
| `npm audit` ≠ `npm audit signatures` | Medium | CVE scanning is different from provenance verification |
| GitHub Release downloads unattested | High | If you download a tarball from Releases, verify SLSA provenance |
| No SBOM of installed toolchain | Medium | You can't find vulns inside compiled binaries without an SBOM |
| SHA recorded but never compared | **High** | A hash that's never diffed is security theater |
| Go binaries never scanned | Medium | Most security tools (trivy, gh, gitleaks) are Go — embedded deps have vulns too |
| Cargo binaries never audited | Low | crates.io has zero Sigstore support — `cargo audit` is all you have |

---

## The Implementation

### 1. Sigstore Provenance Verification (Homebrew)

Homebrew bottles from `homebrew-core` have had SLSA L3 Sigstore attestations since 2024. Most developers don't know this — or that you can verify them independently:

```bash
# Verify your security tools came from the real Homebrew CI
brew verify trivy
brew verify semgrep
brew verify gitleaks
brew verify gh
```

This checks the Sigstore transparency log and confirms the bottle was built by Homebrew's GitHub Actions workflow, from the expected source commit.

**Real output from my system:**
```
[sec]   ✓ provenance verified: trivy
[sec]   ✓ provenance verified: semgrep
[sec]   ✓ provenance verified: gitleaks
[sec]   ✓ provenance verified: osv-scanner
[sec]   ✓ provenance verified: gh
[sec]   ✓ provenance verified: jq
[sec]   ✓ provenance verified: node
[sec]   ✓ provenance verified: python@3.13
[sec]   ✓ provenance verified: go
[ok]    Homebrew provenance: all 9 critical formulae verified
```

### 2. npm Provenance Signatures (Not Just `npm audit`)

`npm audit` checks for known CVEs. `npm audit signatures` checks that packages were built from their claimed source repo via Sigstore:

```bash
# This checks CVEs:
npm audit

# This checks provenance (different!):
npm audit signatures
```

These are complementary, not interchangeable. A package can have zero CVEs but be a complete forgery.

### 3. SBOM + Binary Vulnerability Scanning

Here's the insight most developers miss: **compiled binaries embed their entire dependency tree.** A Go binary built with a vulnerable `net/http` is vulnerable even after you've updated your system Go.

```bash
# Generate an SBOM of all your Homebrew binaries
syft dir:/opt/homebrew/bin -o cyclonedx-json > toolchain-sbom.json

# Scan for embedded vulnerabilities
grype sbom:toolchain-sbom.json --only-fixed --fail-on high
```

**My result:** `grype: no high/critical fixable vulns in toolchain binaries` ✅

### 4. Go Binary Vulnerability Scanning

`govulncheck -mode=binary` is the Go team's official tool for scanning compiled Go binaries. It reads the embedded module info and checks against the Go vulnerability database:

```bash
# Scan your security tools (they're all written in Go!)
govulncheck -mode=binary $(which trivy)
govulncheck -mode=binary $(which gh)
govulncheck -mode=binary $(which gitleaks)
govulncheck -mode=binary $(which osv-scanner)
```

On a first run this surfaced a batch of Go stdlib DoS advisories in one of the scanners above — the binary had been compiled against an older Go toolchain than the one that fixed them. Low risk in a local CLI context, and resolved by a rebuild, but the point is that nothing else I ran would have told me.

### 5. SHA Diff Alerting (The Most Important One)

Recording SHA256 hashes is meaningless if you never compare them. The real value is **detecting unexplained changes**:

```bash
# After every update run, record hashes
shasum -a 256 /opt/homebrew/bin/trivy >> binary-shas.txt

# On next run, compare:
# - If SHA changed AND an update was logged → expected ✅
# - If SHA changed WITHOUT a logged update → RED FLAG 🚨
```

**My implementation detects this automatically:**
```
[sec]   Comparing runs: 2026-08-09 → 2026-08-18
[sec]   ✓ go: SHA changed (update logged)
[ok]    Binary diff: 1 changes, all explained by logged updates
```

If a binary ever changes without a corresponding update in the log, the script flags it as potential tampering.

---

## The Complete Flow

```
┌──────────────────┐
│   brew upgrade   │──→ SHA256 bottle verification (automatic)
│   npm install -g │──→ --ignore-scripts (kill postinstall RCE)
│   uv self update │──→ Sigstore cosign verification (automatic)
│   rustup update  │──→ Signed manifest verification (automatic)
└────────┬─────────┘
         │
         ▼
┌──────────────────────────────────────────────────────┐
│            POST-UPDATE VERIFICATION                   │
├──────────────────────────────────────────────────────┤
│                                                      │
│  1. brew verify (Sigstore provenance)                │
│  2. npm audit signatures (provenance ≠ CVE scan)    │
│  3. gh attestation verify (SLSA L3 for Releases)    │
│  4. syft → grype (SBOM-based binary vuln scan)      │
│  5. codesign -v (macOS signature validation)        │
│  6. SHA diff alerting (detect unexplained changes)   │
│  7. govulncheck -mode=binary (Go embedded deps)     │
│  8. cargo audit (RustSec advisory DB)               │
│                                                      │
└────────┬─────────────────────────────────────────────┘
         │
         ▼
┌──────────────────┐
│  SHA256 snapshot │──→ Baseline for next run's diff
│  SBOM archived   │──→ Audit trail
│  Log recorded    │──→ Evidence
└──────────────────┘
```

---

## What This Catches (Real Examples)

| Scenario | Which layer detects it |
|----------|----------------------|
| `event-stream` style npm hijack | Layer 3 (`--ignore-scripts`) blocks execution |
| Typosquatting Homebrew tap | Layer 3 (tap allowlist blocks unknown taps) |
| Compromised brew bottle | Layer 6 (`brew verify` — Sigstore attestation mismatch) |
| Binary replaced by attacker on disk | Layer 5/6 (SHA diff alert — unexplained change) |
| Vulnerable dependency inside `trivy` | Layer 6 (`govulncheck -mode=binary`) |
| npm package without provenance | Layer 6 (`npm audit signatures` flags it) |
| PATH hijack via world-writable dir | Layer 4 (detected at script startup) |

---

## The Ecosystem Reality Check

Not everything is verifiable yet. Here's the honest state as of 2026:

| Ecosystem | Provenance Coverage | What's available |
|-----------|-------------------|-----------------|
| **Homebrew** | ✅ 100% (homebrew-core) | Sigstore attestations on all bottles |
| **npm** | ⚠️ ~7% of packages | `npm audit signatures` + registry ECDSA |
| **PyPI** | ⚠️ ~17% of uploads | PEP 740 attestations (growing fast) |
| **Go modules** | ✅ Checksums (sum.golang.org) | No Sigstore, but tamper-evident log |
| **crates.io** | ❌ Checksums only | No Sigstore, no provenance |
| **GitHub Releases** | ⚠️ Opt-in | `gh attestation verify` (if publisher enables) |

The strategy is **defense in depth**: verify what you can cryptographically, scan what you can't verify, and detect tampering as a last resort.

---

## Getting Started (15 Minutes)

```bash
# 1. Install the verification tools
brew install syft grype cosign
go install golang.org/x/vuln/cmd/govulncheck@latest
cargo install cargo-audit

# 2. Verify your current Homebrew bottles
for f in trivy semgrep gh node python@3.13 go; do
  brew verify "$f" 2>/dev/null && echo "✓ $f" || echo "✗ $f"
done

# 3. Check npm provenance
npm audit signatures

# 4. Generate your first toolchain SBOM
syft dir:/opt/homebrew/bin -o cyclonedx-json > ~/toolchain-sbom.json
grype sbom:~/toolchain-sbom.json --only-fixed

# 5. Scan Go binaries
govulncheck -mode=binary $(which trivy)
govulncheck -mode=binary $(which gh)

# 6. Create your SHA baseline
for bin in brew node npm go cargo trivy gh; do
  shasum -a 256 "$(which $bin)" >> ~/binary-shas-baseline.txt
done
```

---

## What I Learned

1. **Recording hashes is not monitoring.** A hash file that's never diffed is security theater. You need automated comparison with explainability (was there a logged update or not?).

2. **Your security tools are attack surface.** `trivy`, `semgrep`, `gitleaks` — if these are compromised, they can hide their own findings. Scan the scanners.

3. **`npm audit` is not `npm audit signatures`.** One checks CVEs, the other checks provenance. You need both.

4. **Bash 3.2 is still the default on macOS.** If your security script uses `mapfile` or associative arrays, it silently fails on every Mac. Ship it or test it.

5. **Timeouts matter.** Any network call in a security script that can hang indefinitely will eventually hang indefinitely. I learned this the hard way when Sigstore transparency log queries hung for 90 minutes.

6. **SLSA is a consumer spec too.** Most people think SLSA is for producers/builders. It's equally a spec for how consumers should verify artifacts.

---

## References

- [SLSA v1.0 — Verification specification](https://slsa.dev/spec/v1.0/verifying-artifacts)
- [NIST SP 800-218 (SSDF)](https://csrc.nist.gov/publications/detail/sp/800-218/final)
- [Homebrew Sigstore attestations](https://github.com/Homebrew/brew/issues/17019)
- [npm provenance documentation](https://docs.npmjs.com/generating-provenance-statements)
- [govulncheck binary mode](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
- [Anchore syft + grype](https://github.com/anchore/syft)
- [RustSec Advisory Database](https://rustsec.org/)

---

*The full implementation is a 1,100-line bash script with zero external dependencies. DM me if you want the source.*

---

**Tags:** #SupplyChain #DevSecOps #SLSA #Sigstore #macOS #Homebrew #SBOM #SecurityEngineering
