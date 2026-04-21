#!/usr/bin/env bash
set -euo pipefail

: "${MONGO_USER:?missing}"
: "${MONGO_PASS:?missing}"
: "${MONGO_HOST:?missing}"
: "${OPENAI_API_KEY:=}"
K8S_NAMESPACE="${K8S_NAMESPACE:-chatbot}"

urlenc() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote_plus(sys.argv[1]))' "$1"
  elif command -v python >/dev/null 2>&1; then
    python -c 'import sys, urllib.parse; print(urllib.parse.quote_plus(sys.argv[1]))' "$1"
  elif command -v jq >/dev/null 2>&1; then
    jq -rn --arg s "$1" '$s|@uri'
  else
    printf "%s" "$1"
  fi
}

ENC_USER="$(urlenc "${MONGO_USER}")"
ENC_PASS="$(urlenc "${MONGO_PASS}")"
MONGO_URI="mongodb://${ENC_USER}:${ENC_PASS}@${MONGO_HOST}:27017/stardb?authSource=admin"

kubectl apply -f manifests/namespace.yaml

kubectl -n "${K8S_NAMESPACE}" create secret generic starai-db-secret \
  --from-literal=MONGO_URI="${MONGO_URI}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${OPENAI_API_KEY}" ]]; then
  kubectl -n "${K8S_NAMESPACE}" create secret generic openai-secret \
    --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
