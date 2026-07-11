#!/usr/bin/env bash
#
# quiche/mayhem/test.sh — RUN quiche's own (unmodified) http2_frame_decoder_test gtest suite, built
# by mayhem/build.sh with the project's NORMAL (non-sanitized) flags, and emit a CTRF summary.
# exit 0 iff no test failed.
#
# PATCH-grade oracle: quiche/http2/decoder/http2_frame_decoder_test.cc — untouched by our fuzz-target
# patch — is quiche's REAL assertion suite for the exact code (http2_frame_decoder.cc) that
# http_frame_fuzzer fuzzes: dozens of EXPECT_TRUE/EXPECT_EQ known-answer checks against hand-crafted
# HTTP/2 frame byte sequences (e.g. DecodePayloadAndValidateSeveralWays asserts the decoder produces
# the EXACT expected listener callback sequence for a given frame). A no-op/exit(0) patch to the
# decoder breaks these assertions (wrong/missing callbacks), so it cannot pass. This script only RUNS
# the suite via `bazel test` (already built by build.sh); it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${BAZEL_OUTPUT_USER_ROOT:=/opt/toolchains/bazel/output_user_root}"
: "${BAZEL_REPO_CACHE:=/opt/toolchains/bazel/repo_cache}"
cd "$SRC"

FUZZTEST_BAZELRC="$SRC/mayhem-build/fuzztest.bazelrc"
XML="bazel-testlogs/quiche/http2_frame_decoder_test/test.xml"
rm -f "$XML"   # a stale XML from a previous run must never be mistaken for a fresh result.

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
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

if ! command -v bazel >/dev/null 2>&1; then
  echo "bazel not available — cannot run the test suite" >&2
  emit_ctrf "bazel-test" 0 1 0; exit 2
fi

echo "=== bazel test //quiche:http2_frame_decoder_test ==="
# --nocache_test_results: ALWAYS re-execute the test and write a FRESH JUnit test.xml. Without it,
# bazel returns a CACHED "(cached) PASSED" without re-running (so no new XML) — and since we rm the
# stale XML above, the parser would then see 0 cases and (correctly, per the fail-closed rule below)
# FAIL a genuinely-passing suite. Re-running every time also keeps the anti-reward-hack sabotage check
# honest: a neutered binary actually runs (and produces no/partial XML → detected), never a cache hit.
out="$(bazel --output_user_root="$BAZEL_OUTPUT_USER_ROOT" --bazelrc="$FUZZTEST_BAZELRC" test \
  --repository_cache="$BAZEL_REPO_CACHE" --nocache_test_results \
  --test_output=errors --test_summary=detailed \
  //quiche:http2_frame_decoder_test 2>&1)"; rc=$?
echo "$out"

# Deliberately do NOT trust the process/bazel exit code alone (anti-reward-hacking, SPEC §6.3): under
# sabotage (LD_PRELOAD _exit(0) on program start, before gtest ever runs a case) `bazel test` reports
# the target FAILED TO RUN with no fresh XML — but a naive "exit 0 => pass" fallback would still be
# reward-hackable in other failure shapes, so the ONLY signal we trust is "did gtest's own JUnit
# writer record real test cases". Zero parsed tests is always a FAIL, regardless of the exit code.
TESTS=0; FAILURES=0; ERRORS=0; SKIPPED=0
if [ -f "$XML" ]; then
  PYOUT="$(python3 - "$XML" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
    node = root if root.tag == "testsuite" else root.find(".//testsuite")
    def g(a): return int(node.get(a, 0) or 0)
    print(g("tests"), g("failures"), g("errors"), g("skipped"))
except Exception:
    print(0, 0, 0, 0)
PY
)"
  read -r TESTS FAILURES ERRORS SKIPPED <<< "$PYOUT"
fi
: "${TESTS:=0}" "${FAILURES:=0}" "${ERRORS:=0}" "${SKIPPED:=0}"

if [ "$TESTS" -eq 0 ]; then
  echo "0 gtest cases recorded (missing/empty $XML; bazel test rc=$rc) — treating as FAILURE" >&2
  emit_ctrf "quiche-gtest" 0 1 0
  exit 1
fi

FAILED=$(( FAILURES + ERRORS ))
PASSED=$(( TESTS - FAILED - SKIPPED ))
[ "$PASSED" -ge 0 ] || PASSED=0

emit_ctrf "quiche-gtest" "$PASSED" "$FAILED" "$SKIPPED"
