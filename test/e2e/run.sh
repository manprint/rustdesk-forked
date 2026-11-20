#!/usr/bin/env bash
# End-to-end and stability tests of the shipped proxy configs with a real RustDesk client.
#   ./run.sh [variant...]     variants: apache-ssl nginx-ssl apache-plain nginx-plain allinone-ssl allinone-plain
#                             (default: all)
# Env: RD_HOLD_SECONDS (100)  RD_LOAD_DEVICES (300)  RD_KEEP=1 leaves the last stack up.
set -uo pipefail
cd "$(dirname "$0")"
variants=("$@")
[ ${#variants[@]} -eq 0 ] && variants=(apache-ssl nginx-ssl apache-plain nginx-plain allinone-ssl allinone-plain)
summary=()
rc=0

for v in "${variants[@]}"; do
  [ -f "variant-$v.yml" ] || { echo "unknown variant $v"; exit 2; }
  dc() { docker compose -f docker-compose.test.yml -f "variant-$v.yml" "$@"; }
  step() { # step <name> <command...>
    local name=$1; shift
    echo "=== [$v] $name"
    if "$@"; then summary+=("PASS $v: $name"); else summary+=("FAIL $v: $name"); rc=1; fi
  }
  front=proxy; [[ $v == *-plain ]] && front="proxy edge"
  [[ $v == apache-* ]] && export RD_STATUS_URL=http://proxy:8081/status?auto || export RD_STATUS_URL=
  unset RD_MAX_REG_PER_IP RD_MAX_IDS_PER_IP
  if [[ $v == allinone-* ]]; then
    # One container: s6 has to bring a killed service back by itself.
    srv=proxy
    restart_hbbr() { dc exec -T proxy /command/s6-svc -r /run/service/hbbr; }
    crash_hbbs() { dc exec -T proxy sh -c 'kill -9 $(pidof hbbs)'; }
  else
    srv="hbbs hbbr"
    restart_hbbr() { dc restart hbbr; }
    crash_hbbs() { dc kill hbbs; dc up -d hbbs; }
  fi

  dc down -v --remove-orphans >/dev/null 2>&1
  dc build -q || { summary+=("FAIL $v: build"); rc=1; continue; }
  dc run --rm certs >/dev/null 2>&1
  dc up -d hbbs hbbr $front client >/dev/null 2>&1

  step "protocol, session, keepalive" dc run --rm -T tester e2e

  # hbbs must have recorded client addresses: never the proxies', never a client-supplied header.
  ips_ok() {
    local log bad
    log=$(dc logs --no-log-prefix ${srv%% *} 2>&1 | grep update_pk)
    bad=$(for c in $front; do docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(dc ps -q "$c")"; done)
    echo "$log" | grep -q . || { echo "no registrations logged"; return 1; }
    for ip in $bad 6.6.6.6; do
      if echo "$log" | grep -q " $ip:"; then echo "hbbs recorded $ip"; return 1; fi
    done
    echo "registrations from: $(echo "$log" | awk '{print $8}' | cut -d: -f1 | sort -u | tr '\n' ' ')"
  }
  step "real client address reaches hbbs" ips_ok

  # Reloading the proxy configuration (certificate renewal...) must not cut open tunnels.
  steady() {
    local out pid i r
    out=$(mktemp)
    dc run --rm -T tester steady >"$out" 2>&1 & pid=$!
    # The tester prints READY once its device is registered; its session then idles for 30 s.
    for ((i = 0; i < 120; i++)); do
      grep -q '^READY' "$out" && break
      kill -0 $pid 2>/dev/null || break
      sleep 1
    done
    sleep 5
    if [[ $v == apache-* ]]; then dc exec -T proxy apachectl -k graceful; else dc exec -T proxy nginx -s reload; fi
    wait $pid; r=$?
    cat "$out"; rm -f "$out"
    return $r
  }
  step "open tunnels survive a proxy reload" steady

  dc restart $front >/dev/null 2>&1
  step "recovery after proxy restart" dc run --rm -T tester recover
  restart_hbbr >/dev/null 2>&1
  step "recovery after hbbr restart" dc run --rm -T tester recover
  crash_hbbs >/dev/null 2>&1
  step "recovery after hbbs crash" dc run --rm -T tester recover
  # The load test registers every device from one address: recreate hbbs without the per-IP limits.
  export RD_MAX_REG_PER_IP=100000 RD_MAX_IDS_PER_IP=100000
  dc up -d ${srv%% *} >/dev/null 2>&1
  step "load" dc run --rm -T tester load
  step "real client still fine after the load" dc run --rm -T tester recover

  if dc logs $srv 2>&1 | grep -qiE 'panicked|thread .* panic'; then
    summary+=("FAIL $v: panic in server logs"); rc=1
  fi
  [ -n "${RD_KEEP:-}" ] || dc down -v --remove-orphans >/dev/null 2>&1
done

echo; echo "=========== SUMMARY"
printf '%s\n' "${summary[@]}"
exit $rc
