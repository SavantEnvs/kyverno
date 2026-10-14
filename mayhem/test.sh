#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for kyverno's engine context deferred loaders. Runs the
# dynamically-linked KAT probe (/mayhem/kyverno_deferred_kat, built by build.sh)
# that drives deferred loaders through the real pkg/engine/context, and
# asserts the EXACT query results and loader invocation counts.
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing. The KAT probe is cgo-linked (dynamic), so when
# the program is neutered to _exit(0) it prints nothing, every assertion misses,
# and test.sh FAILS — which is the point (§6.3).
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/kyverno_deferred_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "kyverno-deferred-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Fixed inputs: two deferred loaders ("one"->1, "two"->2) on a fresh context. Querying "one"
# loads only loader one; "[one, two]" then loads two and returns [1 2]; a name that is not on a
# word boundary ("oneTwoThree") matches no loader and errors.
assert() { # <desc> <expected-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert "query 'one' loads loader one and returns 1"  "KAT_ONE=1 err=<nil>"
assert "only loader one ran"                          "KAT_CALLS=1,0"
assert "query '[one, two]' returns [1 2]"             "KAT_BOTH=[1 2] err=<nil>"
assert "loader one is not re-run, loader two ran once" "KAT_CALLS2=1,1"
assert "non-boundary name matches no loader"          "KAT_MISMATCH_ERR=true"

emit_ctrf "kyverno-deferred-kat" "$passed" "$failed"
