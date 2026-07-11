# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). google/quiche (NOT Cloudflare's Rust quiche) is a Bazel/bzlmod
# project (MODULE.bazel + MODULE.bazel.lock) that pulls boringssl, abseil, protobuf, googletest,
# re2, zlib, fuzztest, googleurl et al. as bzlmod deps. Bazel itself + its per-ecosystem caches
# live under /opt/toolchains/bazel (fixed, $HOME-independent — SPEC §6.2 item 8/§6.5) so the same
# populated cache serves the online CI build AND the air-gapped PATCH re-run.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t quiche-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default so an unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

USER root

# zlib1g-dev / libicu-dev: quiche's own OSS-Fuzz Dockerfile installs these (bazel's zlib/googleurl
# bzlmod deps prefer the system copy when present; harmless if unused). unzip/python3 are bazel
# build-time requirements not already guaranteed by the base.
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true; \
    apt-get update && apt-get install -yq --no-install-recommends \
      zlib1g-dev libicu-dev unzip python3 \
    && rm -rf /var/lib/apt/lists/*

# Bazel 8.2.1 — pinned by sha256 (quiche's MODULE.bazel/.bazelversion requires this exact release
# for its bzlmod graph). A single self-contained release binary (bundles its own JVM); no separate
# JDK/bazelisk indirection needed. Lives under /opt/toolchains/bazel (fixed path, §6.2 item 8) along
# with bazel's own output_user_root + repository_cache, so the FIRST (online) build.sh run populates
# those caches here and the air-gapped PATCH re-run resolves the *entire* bzlmod dependency closure
# (boringssl, abseil, protobuf, googletest, re2, zlib, fuzztest, googleurl, ...) from them — see
# mayhem/build.sh for how the cache dirs are wired (BAZEL_OUTPUT_USER_ROOT / BAZEL_REPO_CACHE).
RUN mkdir -p /opt/toolchains/bazel/bin /opt/toolchains/bazel/output_user_root /opt/toolchains/bazel/repo_cache \
    && curl -fsSL -o /opt/toolchains/bazel/bin/bazel \
       https://github.com/bazelbuild/bazel/releases/download/8.2.1/bazel-8.2.1-linux-x86_64 \
    && echo "7ff2b6a675b59a791d007c526977d5262ade8fa52efc8e0d1ff9e18859909fc0  /opt/toolchains/bazel/bin/bazel" | sha256sum -c - \
    && chmod +x /opt/toolchains/bazel/bin/bazel \
    && chown -R mayhem:mayhem /opt/toolchains

ENV PATH="/opt/toolchains/bazel/bin:${PATH}"
ENV BAZEL_OUTPUT_USER_ROOT=/opt/toolchains/bazel/output_user_root
ENV BAZEL_REPO_CACHE=/opt/toolchains/bazel/repo_cache

USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run quiche's own http2_frame_decoder_test gtest suite at build time (a failing suite fails the
# image build) — see mayhem/test.sh.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
