# Contributing

## Reporting a vulnerability

Not here. See [SECURITY.md](SECURITY.md) — use GitHub Security Advisories so the
report stays private until there is a fix.

## Running the tests

```bash
./tests/test-config.sh          # unit tests, no dependencies beyond bash 3.2
bash -n bin/update-toolchain    # syntax
shellcheck -S error bin/update-toolchain tests/test-config.sh
```

CI runs all three on `macos-26` and `macos-26-intel`, plus four behavioural
checks that are easy to regress and awkward to verify by hand. Worth knowing
before you spend time debugging a red build:

- `--dry` and `--audit` must complete non-interactively. A runner has no TTY and
  no password, which makes it the honest test that neither prompts for `sudo`.
- Piped output must contain no ANSI escape codes.
- `--json` must emit valid JSON on stdout with progress on stderr.

## Constraints worth knowing before you write code

**bash 3.2.** That is the version macOS ships, and this tool must run on a stock
machine without asking anyone to upgrade a shell first. No associative arrays
(`declare -A`), no `mapfile`/`readarray`, no `${var,,}`. There is a test that
fails if any of those appear.

**Configuration is data, never code.** Allowlists are newline-delimited text,
parsed with `sed` and `grep`. Do not make the loader `source` a config file. A
sourced config means anyone who can write your config can execute code as you,
which turns the configuration surface of a security tool into a privilege
escalation path. A test fails if the loader ever gains that ability.

**Read-only modes must stay read-only.** `--dry` and `--audit` must not prompt
for `sudo`, write outside the log directory, or mutate any package. Sudo is
primed once, gated behind a mode check; any new `sudo` call needs the same gate.
This has regressed before.

**Mind `set -euo pipefail`.** `cmd | grep pattern | while read` aborts the whole
run when `grep` matches nothing, which is the ordinary case on a machine that
does not have the thing being inspected. Wrap it: `| { grep pattern || true; } |`.
This shipped as a real bug — `--dry` died on any machine with no
cargo-installed binaries.

**Every status needs a text label.** Colour is decoration, never the only signal
— it is absent whenever output is redirected, and unavailable to plenty of
readers.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | clean, or findings below the `--fail-on` threshold |
| `1` | findings at or above `--fail-on` |
| `2` | the tool itself could not complete |

Keep these distinct. A pipeline has to be able to tell "this machine has a
problem" from "this tool broke"; conflating them is a well-known scanner
anti-pattern.

## Adding a check

Security checks live in numbered sections in `bin/update-toolchain`. A new one
should:

- use `require <binary>` and skip cleanly when the tool is absent, rather than
  failing the run
- honour `$DRY` — print what it would do, change nothing
- report through `sec`/`warn`/`err`, and use `detail` for remediation text and
  captured output so it is not tallied as a separate finding
- bump `PHASE_TOTAL` if it adds a phase

Prefer a false negative to a false positive. A check that fires on a healthy
machine teaches people to ignore the output, which is worse than not having the
check. The world-writable PATH check shipped broken for exactly this reason: it
flagged every group-writable directory, which is Homebrew's own normal layout.

## Releasing

Formula and bottles live in
[prasannavarshan/homebrew-tap](https://github.com/prasannavarshan/homebrew-tap);
its README documents the release flow. Bottles are built on a pull request and
published by a manual workflow, never by merging.
