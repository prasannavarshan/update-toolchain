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
