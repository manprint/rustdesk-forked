FROM ubuntu:24.04
ARG RUSTDESK_CLIENT_VERSION=1.5.3
ENV DEBIAN_FRONTEND=noninteractive
ADD https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_CLIENT_VERSION}/rustdesk-${RUSTDESK_CLIENT_VERSION}-x86_64.deb /tmp/rustdesk.deb
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates xvfb dbus /tmp/rustdesk.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/rustdesk.deb
COPY entrypoint.sh gen-certs.sh /
ENTRYPOINT ["/entrypoint.sh"]
