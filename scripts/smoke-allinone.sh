#!/usr/bin/env bash
# Starts the all-in-one image in plain mode with the hardening of compose.allinone.yml and checks
# that it gets healthy, upgrades /ws/id and /ws/relay to WebSocket and answers 404 elsewhere.
#   scripts/smoke-allinone.sh IMAGE [HOST_PORT]
set -euo pipefail
image=${1:?usage: smoke-allinone.sh IMAGE [HOST_PORT]}
port=${2:-18080}
name=rd-smoke-$$
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /run:exec,uid=10001,gid=10001,mode=0755 --tmpfs /tmp:uid=10001,gid=10001,mode=0700 \
  --tmpfs /data:uid=10001,gid=10001,mode=0700 \
  -e RD_DOMAIN=rd.test -e RD_MODE=plain -e RD_EDGE_PROXY=127.0.0.1 \
  -p "127.0.0.1:$port:8080" "$image" >/dev/null

status=starting
for _ in $(seq 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$name")
  [ "$status" = healthy ] && break
  sleep 1
done
if [ "$status" != healthy ]; then
  echo "FAIL container is $status"; docker logs "$name" 2>&1 | tail -30; exit 1
fi
echo "PASS container healthy"

rc=0
code() { # code <path> [curl options...]: the WebSocket upgrade never ends, so curl times out by design
  local path=$1; shift
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 3 "$@" "http://127.0.0.1:$port$path" || true
}
expect() { # expect <wanted> <got> <what>
  if [ "$1" = "$2" ]; then echo "PASS $3 is $2"; else echo "FAIL $3 is $2, wanted $1"; rc=1; fi
}
ws=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')
expect 101 "$(code /ws/id "${ws[@]}")" "/ws/id upgrade"
expect 101 "$(code /ws/relay "${ws[@]}")" "/ws/relay upgrade"
expect 404 "$(code /)" "/"
expect 404 "$(code /ws/id)" "/ws/id without upgrade"
logs=$(docker logs "$name" 2>&1)
if grep -q 'Key: ' <<<"$logs"; then echo "PASS hbbs printed its key"; else echo "FAIL hbbs did not print its key"; rc=1; fi
exit $rc
