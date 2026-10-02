#!/usr/bin/env bash
set -euo pipefail

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

ok()   { echo "[ OK ] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

portfwd() { # namespace service local_port remote_port
  kubectl -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PIDS+=($!)
}

wait_http() { # url
  for _ in $(seq 1 20); do curl -fs "$1" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

promq() {
  curl -sG --data-urlencode "query=$1" "http://127.0.0.1:19090/api/v1/query" \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")'
}

# 1. Cluster
kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null \
  && ok "node is Ready" || fail "node is not Ready"

# 2. Gateway API
NP=$(kubectl -n demo get svc web-gw-nginx -o jsonpath='{.spec.ports[0].nodePort}')
resp=$(curl -fsS -H "Host: hello.local" "http://127.0.0.1:${NP}/")
[ "$resp" = "Hello World!" ] && ok "gateway: Hello World! via NodePort ${NP}" || fail "gateway: got '${resp}'"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NP}/")
[ "$code" = "404" ] && ok "gateway: unknown host returns 404" || fail "gateway: expected 404, got ${code}"

# unique marker for the logging check
MARK="verify$(date +%s)"
for _ in $(seq 1 5); do curl -s -o /dev/null -A "$MARK" -H "Host: hello.local" "http://127.0.0.1:${NP}/"; done

# 3. Prometheus
portfwd monitoring kps-kube-prometheus-stack-prometheus 19090 9090
wait_http "http://127.0.0.1:19090/-/ready" || fail "prometheus is not reachable"
down=$(promq 'count(up==0) or vector(0)')
[ "$down" = "0" ] && ok "prometheus: all targets are up" || fail "prometheus: ${down} target(s) down"
[ -n "$(promq 'sum(nginx_http_requests_total)')" ] && ok "prometheus: nginx_http_requests_total is collected" \
  || fail "prometheus: no nginx metrics"
curl -s http://127.0.0.1:19090/api/v1/rules | grep -q WebNoAvailableReplicas \
  && ok "prometheus: alert rules loaded" || fail "prometheus: alert rules missing"

# 4. Logs (Filebeat -> Elasticsearch)
portfwd logging elasticsearch 19200 9200
wait_http "http://127.0.0.1:19200/" || fail "elasticsearch is not reachable"
n=0
for _ in $(seq 1 12); do
  n=$(curl -sG --data-urlencode "q=message:${MARK}" "http://127.0.0.1:19200/demo-logs*/_count" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("count",0))')
  [ "$n" -gt 0 ] && break
  sleep 5
done
[ "$n" -gt 0 ] && ok "logs: ${n} access-log entries found in Elasticsearch" || fail "logs: marker ${MARK} not found"

echo "All checks passed."