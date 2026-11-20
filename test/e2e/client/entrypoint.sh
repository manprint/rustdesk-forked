#!/bin/sh
# Real RustDesk client in "controlled device" mode, WebSocket only.
set -eu
cp /certs/ca.crt /usr/local/share/ca-certificates/rd-test-ca.crt
update-ca-certificates >/dev/null 2>&1
while [ ! -s /keys/id_ed25519.pub ]; do sleep 1; done
mkdir -p /root/.config/rustdesk
cat > /root/.config/rustdesk/RustDesk2.toml <<TOML
rendezvous_server = 'rd.test:21116'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = 'rd.test'
api-server = 'https://rd.test'
key = '$(cat /keys/id_ed25519.pub)'
allow-websocket = 'Y'
TOML
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
export DISPLAY=:99
sleep 1
( sleep 8; rustdesk --password "${RD_PASSWORD:-E2e-Test-1234}" >/dev/null 2>&1 || true
  rustdesk --get-id > /shared/client_id.tmp 2>/dev/null && mv /shared/client_id.tmp /shared/client_id ) &
exec rustdesk --server
