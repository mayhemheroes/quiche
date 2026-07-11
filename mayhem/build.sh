#!/usr/bin/env bash
#
# quiche/mayhem/build.sh — build a libFuzzer harness for google/quiche's HTTP/2 frame decoder
# (quiche/http2/decoder/http2_frame_decoder.{h,cc}) via Bazel, AND quiche's own
# http2_frame_decoder_test gtest suite (for mayhem/test.sh).
#
# quiche (google/quiche — NOT Cloudflare's Rust quiche) is a Bazel/bzlmod project (MODULE.bazel +
# MODULE.bazel.lock) that pulls boringssl, abseil, protobuf, googletest, re2, zlib, fuzztest,
# googleurl, highwayhash, quic-trace, anonymous-tokens as bzlmod deps. Bazel itself + its caches live
# under /opt/toolchains/bazel (Dockerfile; fixed, $HOME-independent — SPEC §6.2 item 8/§6.5): the
# FIRST (online, in CI) run of this script populates --output_user_root/--repository_cache there;
# nothing else in this script changes between runs, so the air-gapped PATCH re-run resolves the
# WHOLE dependency closure from that cache with bazel reporting "nothing to do" — no network needed.
#
# HARNESS NOTE: quiche's own OSS-Fuzz recipe (projects/quiche/build.sh upstream) wraps a fuzztest
# FUZZ_TEST (patched into the shared http2_frame_decoder_test.cc) behind a `--fuzz=Suite.Test`
# selector shell wrapper. That's incompatible with Mayhem: a Mayhemfile `cmd:` target (and our local
# fuzz-smoke gate) must be a directly-runnable libFuzzer ELF, not a script, and not a binary that
# needs an extra selector flag before the libFuzzer args. So instead we add our OWN small,
# additive-only harness (mayhem/patches/quiche-fuzz-target.diff): a new .cc file with a plain
# `LLVMFuzzerTestOneInput` (same decoder entry point/no-op listener as quiche's own bazel-unwired
# quiche/http2/decoder/http2_frame_decoder_fuzzer.cc FUZZ_TEST) + a new cc_binary BUILD.bazel rule —
# a genuine standalone libFuzzer binary, no fuzztest/gtest scaffolding, no selector argument needed.
# This leaves quiche/http2/decoder/http2_frame_decoder_test.cc completely untouched, so its own
# individually-named //quiche:http2_frame_decoder_test gtest target stays buildable/runnable
# unmodified — that's mayhem/test.sh's oracle.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${BAZEL_OUTPUT_USER_ROOT:=/opt/toolchains/bazel/output_user_root}"
: "${BAZEL_REPO_CACHE:=/opt/toolchains/bazel/repo_cache}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS
mkdir -p "$BAZEL_OUTPUT_USER_ROOT" "$BAZEL_REPO_CACHE"

cd "$SRC"   # /mayhem — the quiche checkout root (MODULE.bazel lives here) + our mayhem/ layer.

# Bazel rc: written under $SRC (not /etc — build.sh runs as non-root `mayhem`) and threaded via
# --bazelrc on every invocation; bazel reads it AFTER quiche's own committed workspace .bazelrc, so
# our --config=oss-fuzz flags (gated, only active when we pass --config=oss-fuzz) layer on top of
# quiche's always-on `build --cxxopt=...` lines without conflict.
FUZZTEST_BAZELRC="$SRC/mayhem-build/fuzztest.bazelrc"
mkdir -p "$(dirname "$FUZZTEST_BAZELRC")"
: > "$FUZZTEST_BAZELRC"

bz() {
  local cmd="$1"; shift
  command bazel --output_user_root="$BAZEL_OUTPUT_USER_ROOT" --bazelrc="$FUZZTEST_BAZELRC" \
    "$cmd" --repository_cache="$BAZEL_REPO_CACHE" --jobs="$MAYHEM_JOBS" "$@"
}

# ── 0) Apply our additive fuzz-target patch (adds a new .cc harness + a new cc_binary BUILD.bazel
#       rule named //quiche:http_frame_fuzzer). Idempotent: build.sh may be re-run (PATCH tier)
#       against an already-patched tree. ──────────────────────────────────────────────────────────
PATCH="$SRC/mayhem/patches/quiche-fuzz-target.diff"
if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SRC" apply "$PATCH"
  echo "applied $PATCH"
elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "$PATCH already applied — re-run, skipping"
else
  echo "FATAL: $PATCH does not apply cleanly (and isn't already applied) — upstream moved?" >&2
  exit 1
fi

# ── 1) DWARF<4 anchor object (§6.2 item 10, defensive). ──────────────────────────────────────────
# On some clang builds a prebuilt, --whole-archive-linked compiler-rt runtime can carry its OWN
# baked-in DWARF5 debug info and land as the first .debug_info compile unit, defeating -gdwarf-3 on
# every object we DO compile (this bit a fuzztest-heavy Bazel build against OSS-Fuzz's own custom
# clang during development). Debian's packaged clang-19 runtimes ship with NO embedded debug info at
# all, so this isn't currently triggered here — but the anchor costs nothing and is cheap insurance
# (same trick as the validated Rust cc-wrapper-anchor recipe): a tiny -gdwarf-3 object linked as the
# very FIRST linkopt, so IF any runtime CU ever lands first, ours still does.
ANCHOR_OBJ="$BAZEL_OUTPUT_USER_ROOT/../mayhem-dwarf3-anchor.o"
{ TMPD_ANCHOR="$(mktemp -d)"; printf 'int mayhem_dwarf3_anchor(void){return 0;}\n' > "$TMPD_ANCHOR/anchor.c"; }
$CC -g -gdwarf-3 -c "$TMPD_ANCHOR/anchor.c" -o "$ANCHOR_OBJ"

# ── 2) Generate the fuzztest OSS-Fuzz bazelrc block (--config=oss-fuzz) from our contract's flags.
#       setup_configs only emits the oss-fuzz block when $FUZZING_ENGINE and $SANITIZER are set; it
#       translates $CFLAGS/$CXXFLAGS (word-split, comma-in-value split) into --conlyopt/--cxxopt/
#       --linkopt for `--config=oss-fuzz`. -fsanitize=fuzzer-no-link adds SanitizerCoverage
#       instrumentation project-wide WITHOUT pulling in a `main()`; the plain (non-whole-archive)
#       libFuzzer runtime linkopt it also emits (FUZZING_ENGINE=libfuzzer) is exactly what our new,
#       single-TU cc_binary harness needs (no gtest_main to conflict with — no whole-archive/link-
#       order workaround required this time, unlike the fuzztest/gtest wrapper approach). ──────────
export SANITIZER=address
export FUZZING_ENGINE=libfuzzer
export CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
export CXXFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
bz run @fuzztest//bazel:setup_configs >> "$FUZZTEST_BAZELRC"

# setup_configs only auto-adds the UBSan runtime when $SANITIZER is LITERALLY "undefined" (we set
# "address" above, to get the oss-fuzz block emitted at all) — add it explicitly so ASan+UBSan are
# both actually linked, matching $SANITIZER_FLAGS="-fsanitize=address,undefined ...".
UBSAN_CXX="$(find /usr -iname 'libclang_rt.ubsan_standalone_cxx*' 2>/dev/null | grep -E 'x86_64' | grep -v '\.syms' | head -1)"
[ -n "$UBSAN_CXX" ] || { echo "FATAL: libclang_rt.ubsan_standalone_cxx*.a not found" >&2; exit 1; }

# The FUZZING_ENGINE=libfuzzer branch of setup_configs links libclang_rt.fuzzer_no_main*.a — a
# runtime WITHOUT `main()` (fuzztest binaries provide their own via gtest_main + FUZZ_TEST). Our
# harness is a plain LLVMFuzzerTestOneInput with NO gtest/fuzztest driver of its own, so it needs the
# FULL libFuzzer runtime (main() + driver) instead — drop the no-main linkopt and link $LIB_FUZZING_ENGINE
# (-fsanitize=fuzzer) directly, exactly like every other C/C++ repo in this fleet.
sed -i '\|--linkopt=.*fuzzer_no_main|d' "$FUZZTEST_BAZELRC"

# ── 3) Build the sanitized libFuzzer target: //quiche:http_frame_fuzzer ─────────────────────────
bz build --config=oss-fuzz --strip=never \
  --linkopt="$ANCHOR_OBJ" \
  --linkopt="$UBSAN_CXX" \
  --linkopt="$LIB_FUZZING_ENGINE" \
  //quiche:http_frame_fuzzer

cp -f bazel-bin/quiche/http_frame_fuzzer /mayhem/http_frame_fuzzer
chmod +x /mayhem/http_frame_fuzzer

# Standalone (non-fuzzing) reproducer: a plain libFuzzer binary run with ONE positional file argument
# (no flags) replays that input once and exits — standard libFuzzer behavior, so the same ELF serves
# both roles; ship a copy under the -standalone name for the human/repro convention.
cp -f /mayhem/http_frame_fuzzer /mayhem/http_frame_fuzzer-standalone
chmod +x /mayhem/http_frame_fuzzer-standalone

# ── 4) mayhem/test.sh's oracle. ───────────────────────────────────────────────────────────────────
# quiche/http2/decoder/http2_frame_decoder_test.cc is UNTOUCHED by our patch (see the file header),
# so its own individually-named //quiche:http2_frame_decoder_test cc_test (auto-generated by
# quiche_tests_srcs' test_suite_from_source_list) builds and runs exactly as upstream ships it —
# dozens of real EXPECT_TRUE/EXPECT_EQ known-answer checks against hand-crafted HTTP/2 frame bytes,
# for the SAME decoder code http_frame_fuzzer fuzzes. Build it now (normal bazel config — a separate,
# clean, non-sanitized build, so test.sh stays an honest, independent PATCH oracle).
bz build --strip=never //quiche:http2_frame_decoder_test

echo "build.sh complete:"
ls -la /mayhem/http_frame_fuzzer /mayhem/http_frame_fuzzer-standalone bazel-bin/quiche/http2_frame_decoder_test 2>&1 || true
