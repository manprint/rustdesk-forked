# syntax=docker/dockerfile:1
# hbbs + hbbr built from the vendored source in ./server into a static image with no shell.
ARG RUST_IMAGE=rust:1.100-alpine3.24@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33

FROM ${RUST_IMAGE} AS build
RUN apk add --no-cache build-base musl-dev perl pkgconfig openssl-dev openssl-libs-static
WORKDIR /src
COPY server/ .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked --bin hbbs --bin hbbr \
 && install -D -t /out/usr/bin target/release/hbbs target/release/hbbr \
 && install -d -o 10001 -g 10001 -m 0700 /out/data

FROM scratch
COPY --from=build /out/ /
USER 10001:10001
WORKDIR /data
ENV HOME=/data
VOLUME /data
