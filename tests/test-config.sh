#!/usr/bin/env bash
# Tests for the config loader. No dependencies beyond bash 3.2 + coreutils.
#   ./tests/test-config.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/update-toolchain"

PASS=0; FAIL=0
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the Config section verbatim so we exercise the real load_list, not a
# copy of it. load_list depends only on CONFIG_DIR, EXAMPLE_DIR and BREW_PREFIX,
# so the harness sources the block as-is and then overrides those three.
harness="$TMP/harness.sh"
sed -n '/^# ── Config ─/,/^# ── /{ /^# ── [^C]/q; p; }' "$SCRIPT" > "$harness"

grep -q 'load_list()' "$harness" || { echo "FATAL: could not extract load_list"; exit 1; }

echo "== load_list =="

run_load() { # run_load <cfgdir> <exampledir> <name>
  ( set -uo pipefail
    # shellcheck disable=SC1090
    source "$harness"
    BREW_PREFIX="/opt/testbrew"
    CONFIG_DIR="$1"
    EXAMPLE_DIR="$2/config"
    load_list "$3" )
}

mkdir -p "$TMP/ex/config" "$TMP/cfg"

# 1. comments, blank lines, indentation, trailing comments
cat > "$TMP/ex/config/list-a.example" <<'EOF'
# a leading comment
alpha
   beta
gamma   # trailing comment

   # indented comment
delta
EOF
got="$(run_load "$TMP/nonexistent" "$TMP/ex" list-a | tr '\n' ',')"
check "strips comments, blanks and indentation" "alpha,beta,gamma,delta," "$got"

# 2. user config overrides the bundled example
echo "override-only" > "$TMP/cfg/list-a"
got="$(run_load "$TMP/cfg" "$TMP/ex" list-a | tr '\n' ',')"
check "user config wins over example" "override-only," "$got"

# 3. missing list is empty, not an error
got="$(run_load "$TMP/cfg" "$TMP/ex" no-such-list; echo "rc=$?")"
check "missing list yields empty + rc=0" "rc=0" "$got"

# 4. \${BREW_PREFIX} expansion (Intel vs Apple Silicon portability)
cat > "$TMP/ex/config/list-b.example" <<'EOF'
${BREW_PREFIX}/bin/gh
/Applications/Thing.app
EOF
got="$(run_load "$TMP/nonexistent" "$TMP/ex" list-b | tr '\n' ',')"
check "expands \${BREW_PREFIX}" "/opt/testbrew/bin/gh,/Applications/Thing.app," "$got"

echo "== config is data, never code =="

# 5. A config file must not be able to execute anything. If the loader ever
#    sourced config, this would create the canary file.
canary="$TMP/canary"
cat > "$TMP/ex/config/list-c.example" <<EOF
\$(touch "$canary")
\`touch "$canary"\`
safe-entry
EOF
run_load "$TMP/nonexistent" "$TMP/ex" list-c >/dev/null
if [[ -e "$canary" ]]; then
  bad "config cannot execute code" "canary was created — loader executed config content"
else
  ok "config cannot execute code"
fi

echo "== _other_writable =="

# Extract the predicate itself so the test exercises shipped code.
ow="$TMP/ow.sh"
sed -n '/^_other_writable() {/,/^}/p' "$SCRIPT" > "$ow"
grep -q '_other_writable' "$ow" || { echo "FATAL: could not extract _other_writable"; exit 1; }

ow_test() { # ow_test <mode> -> "yes"/"no"
  ( set -uo pipefail
    # shellcheck disable=SC1090
    source "$ow"
    if _other_writable "$1"; then echo yes; else echo no; fi )
}

# Group-writable is Homebrew's own normal layout. Flagging it as world-writable
# was a false positive on every correctly configured machine.
check "drwxrwxr-x is NOT other-writable" "no"  "$(ow_test 'drwxrwxr-x')"
check "drwxr-xr-x is NOT other-writable" "no"  "$(ow_test 'drwxr-xr-x')"
check "drwx------ is NOT other-writable" "no"  "$(ow_test 'drwx------')"
# Position 9 is other-write. Position 8 is other-read; an off-by-one here read
# the wrong column entirely.
check "drwxrwxrwx IS other-writable"     "yes" "$(ow_test 'drwxrwxrwx')"
check "drwxr-xrwx IS other-writable"     "yes" "$(ow_test 'drwxr-xrwx')"
# Sticky /tmp-style: other still has write.
check "drwxrwxrwt IS other-writable"     "yes" "$(ow_test 'drwxrwxrwt')"
# Degenerate input must not throw under set -u.
check "short string is NOT other-writable" "no" "$(ow_test 'drwx')"
check "empty string is NOT other-writable" "no" "$(ow_test '')"

echo "== _exit_code (--fail-on gate) =="

# _exit_code reads counts back out of the log file, so a fabricated log is
# enough to drive every branch deterministically.
gate="$TMP/gate.sh"
{
  sed -n '/^_tally() {/,/^}/p' "$SCRIPT"
  sed -n '/^_exit_code() {/,/^}/p' "$SCRIPT"
} > "$gate"
grep -q '_exit_code' "$gate" || { echo "FATAL: could not extract _exit_code"; exit 1; }

gate_test() { # gate_test <fail_on> <n_warn> <n_err> -> exit code
  ( set -uo pipefail
    LOG_FILE="$TMP/fake.log"; : > "$LOG_FILE"
    local i=0
    while [[ $i -lt $2 ]]; do echo "ts [WARN]  w$i" >> "$LOG_FILE"; i=$((i+1)); done
    i=0
    while [[ $i -lt $3 ]]; do echo "ts [ERROR] e$i" >> "$LOG_FILE"; i=$((i+1)); done
    FAIL_ON="$1"
    # shellcheck disable=SC1090
    source "$gate"
    _exit_code && echo 0 || echo 1 )
}

# never: always success, however bad the findings. This is the default so that
# a local run reports without returning a scary status.
check "never + 0 findings  -> 0" "0" "$(gate_test never 0 0)"
check "never + warns+errs  -> 0" "0" "$(gate_test never 3 2)"
# error: only errors gate.
check "error + 0 findings  -> 0" "0" "$(gate_test error 0 0)"
check "error + warns only  -> 0" "0" "$(gate_test error 5 0)"
check "error + 1 error     -> 1" "1" "$(gate_test error 0 1)"
# warn: either level gates.
check "warn  + 0 findings  -> 0" "0" "$(gate_test warn 0 0)"
check "warn  + 1 warning   -> 1" "1" "$(gate_test warn 1 0)"
check "warn  + 1 error     -> 1" "1" "$(gate_test warn 0 1)"

echo "== read-only modes =="

# 6. --dry and --audit must not prompt for sudo. Grep the source rather than
#    running them, so the test stays fast and network-free.
if sed -n '/^# ── Sudo credential cache ─/,/^fi$/p' "$SCRIPT" | grep -q 'if \$DRY || \$AUDIT_ONLY; then'; then
  ok "sudo priming is gated on --dry/--audit"
else
  bad "sudo priming is gated on --dry/--audit" "gate not found in sudo block"
fi

ungated="$(grep -c '^sudo -v' "$SCRIPT" || true)"
check "no ungated top-level 'sudo -v'" "0" "$ungated"

# 7. Untrusted taps must not abort a read-only run
if grep -q 'Untrusted taps present (continuing — read-only mode)' "$SCRIPT"; then
  ok "untrusted taps warn (not die) in read-only mode"
else
  bad "untrusted taps warn (not die) in read-only mode" "warn branch not found"
fi

echo "== rule catalog (spec 0004) =="

CATALOG="$ROOT/config/rules.example"

# AC2: every catalog row has exactly five pipe-delimited fields. A truncated
# row (empty remediation instead of the em-dash placeholder) is a bug.
if [[ -f "$CATALOG" ]]; then
  bad_rows=0
  while IFS= read -r cline; do
    # strip comments/blanks the way load_list does
    cline="$(printf '%s' "$cline" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$cline" ]] && continue
    nf=$(printf '%s' "$cline" | awk -F'|' '{print NF}')
    if [[ "$nf" -ne 5 ]]; then
      bad_rows=$((bad_rows+1))
      printf '       offending row (%d fields): %s\n' "$nf" "$cline"
    fi
  done < "$CATALOG"
  check "every catalog row has exactly 5 fields" "0" "$bad_rows"
else
  bad "catalog exists" "config/rules.example not found"
fi

# AC1: every rule ID referenced by a `finding` call site exists in the catalog.
# A typo becomes a test failure, not a silently unlabelled finding. We match
# `finding <id>` where <id> is a literal domain.rule (skip the internal
# recursive call which uses the same literal, and any dynamic ids — there are
# none today).
missing_ids=""
while IFS= read -r fid; do
  [[ -z "$fid" ]] && continue
  if ! grep -qE "^${fid}[[:space:]]*\|" "$CATALOG"; then
    missing_ids="$missing_ids $fid"
  fi
done < <(grep -oE 'finding[[:space:]]+[a-z][a-z0-9-]*\.[a-z0-9-]+' "$SCRIPT" \
           | awk '{print $2}' | sort -u)
check "every finding() call-site id is in the catalog" "" "$missing_ids"

# AC6 / config-is-data: the canary must extend to config/rules. Remediation
# text contains ${VAR} and backticks as prose; loading must never evaluate it.
rules_canary="$TMP/rules_canary"
cat > "$TMP/ex/config/rules.example" <<EOF
evil.rule | error | \$(touch "$rules_canary") | \`touch "$rules_canary"\` | x
EOF
run_load "$TMP/nonexistent" "$TMP/ex" rules >/dev/null
if [[ -e "$rules_canary" ]]; then
  bad "rule catalog cannot execute code" "canary created — catalog was evaluated"
else
  ok "rule catalog cannot execute code"
fi

# severity -> level mapping and AC9: log line is `[LEVEL] [rule.id] message`,
# with the rule id extractable as a second bracketed field via sed. Exercise
# the shipped finding() by sourcing the config block (for load_list) plus the
# logging block (for finding() itself).
fx="$TMP/finding.sh"
{
  sed -n '/^# ── Config ─/,/^# ── /{ /^# ── [^C]/q; p; }' "$SCRIPT"
  sed -n '/^# ── Logging ─/,/^# ── Summary ─/p' "$SCRIPT"
} > "$fx"
grep -q 'finding()' "$fx"  || { echo "FATAL: could not extract finding()"; exit 1; }
grep -q 'load_list()' "$fx" || { echo "FATAL: could not extract load_list()"; exit 1; }

finding_test() { # finding_test <severity-in-catalog> -> "LEVEL|extracted-id"
  ( set -uo pipefail
    mkdir -p "$TMP/fxex/config"
    printf 'demo.rule | %s | Demo | fix it | SECURITY.md Layer 1\n' "$1" > "$TMP/fxex/config/rules.example"
    # shellcheck disable=SC1090
    source "$fx"
    # Override AFTER sourcing: the sourced Config and Logging blocks re-assign
    # EXAMPLE_DIR and LOG_FILE. Setting them before source would be clobbered —
    # in particular LOG_FILE would point at the real timestamped log, and two
    # calls in the same second would share it (the bug this ordering fixes).
    C_RED=""; C_YELLOW=""; C_MAGENTA=""; C_RESET=""; C_DIM=""; C_BLUE=""; C_GREEN=""; C_BOLD=""
    CONFIG_DIR="$TMP/fxcfg"; EXAMPLE_DIR="$TMP/fxex/config"; BREW_PREFIX="/opt/testbrew"
    LOG_FILE="$TMP/fx.log"; : > "$LOG_FILE"
    finding demo.rule "the-subject" "extra" >/dev/null 2>&1
    local logged lvl rid
    logged="$(grep '\[demo\.rule\]' "$LOG_FILE" | head -1)"
    lvl=$(printf '%s' "$logged" | sed -n 's/^[^ ]* \[\([A-Z]*\)\].*/\1/p')
    rid=$(printf '%s' "$logged" | sed -n 's/^[^ ]* \[[A-Z]*\] \[\([a-z][a-z0-9.-]*\)\].*/\1/p')
    printf '%s|%s' "$lvl" "$rid" )
}

check "severity error  -> ERROR, id extractable" "ERROR|demo.rule" "$(finding_test error)"
check "severity warning -> WARN, id extractable"  "WARN|demo.rule"  "$(finding_test warning)"
check "severity info    -> SEC, id extractable"   "SEC|demo.rule"   "$(finding_test info)"

echo "== syntax =="
if bash -n "$SCRIPT" 2>/dev/null; then ok "bin/update-toolchain parses"; else bad "bin/update-toolchain parses"; fi

# bash 3.2 is the stock macOS bash; these constructs would break it
for pat in 'declare -A' 'mapfile' 'readarray'; do
  n="$(grep -c "$pat" "$SCRIPT" || true)"
  check "bash 3.2 safe: no '$pat'" "0" "$n"
done

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
