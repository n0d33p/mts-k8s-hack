#!/usr/bin/env bash
set -euo pipefail

NP=$(kubectl -n demo get svc web-gw-nginx -o jsonpath='{.spec.ports[0].nodePort}')
echo "[gateway] NodePort=${NP}"

resp=$(curl -fsS -H "Host: hello.local" "http://127.0.0.1:${NP}/")
if [ "${resp}" = "Hello World!" ]; then
  echo "[gateway] OK: ${resp}"
else
  echo "[gateway] FAIL: got '${resp}'"
  exit 1
fi
