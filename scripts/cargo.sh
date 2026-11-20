#!/usr/bin/env bash
# Runs cargo on server/ inside the pinned build image of the Dockerfile (no local Rust needed).
#   scripts/cargo.sh test --locked     unit tests
#   scripts/cargo.sh update            refresh Cargo.lock with patched dependencies
#   scripts/cargo.sh audit             known vulnerabilities in Cargo.lock (installs cargo-audit once)
set -euo pipefail
cd "$(dirname "$0")/.."
image=$(sed -n 's/^ARG RUST_IMAGE=//p' Dockerfile)
pre='apk add --no-cache build-base musl-dev perl pkgconfig openssl-dev openssl-libs-static >/dev/null'
[ "${1:-}" = audit ] && pre="$pre && (command -v cargo-audit >/dev/null || cargo install --locked cargo-audit >/dev/null 2>&1)"
docker run --rm -v "$PWD/server:/src" -w /src \
  -v rustdesk-cargo-home:/usr/local/cargo/registry -v rustdesk-cargo-bin:/usr/local/cargo/bin-extra \
  -v rustdesk-cargo-target:/target -e CARGO_TARGET_DIR=/target -e CARGO_INSTALL_ROOT=/usr/local/cargo/bin-extra \
  -e PATH=/usr/local/cargo/bin-extra/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "$image" sh -c "$pre && cargo \"\$@\"; rc=\$?; chown $(id -u):$(id -g) Cargo.lock; exit \$rc" cargo "$@"
