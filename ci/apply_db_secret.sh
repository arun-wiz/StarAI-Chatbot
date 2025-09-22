#!/usr/bin/env bash
set -euo pipefail

: "${EKS_CLUSTER_NAME_B:?missing}"
: "${EKS_REGION_B:?missing}"

# Encode username/password per RFC 3986 to satisfy PyMongo URI parsing
urlenc() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote_plus(sys.argv[1]))' "$1"
  elif command -v python >/dev/null 2>&1; then
    python -c 'import urllib.parse,sys; print(urllib.parse.quote_plus(sys.argv[1]))' "$1"
  elif command -v jq >/dev/null 2>&1; then
    jq -rn --arg s "$1" '$s|@uri'
  else
    # last resort: no encoding tool available
    printf "%s" "$1"
  fi
}

ENC_USER="$(urlenc "$MONGO_USER")"
ENC_PASS="$(urlenc "$MONGO_PASS")"
MONGO_URI="mongodb://${ENC_USER}:${ENC_PASS}@${MONGO_HOST}:27017/stardb?authSource=admin"


export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME_B" --region "$EKS_REGION_B" --kubeconfig "$KUBECONFIG"

ROLE_ARN="$(aws sts get-caller-identity --query Arn --output text | sed -E 's|^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*$|arn:aws:iam::\1:role/\2|')"

aws eks create-access-entry \
  --cluster-name "$EKS_CLUSTER_NAME_B" \
  --principal-arn "$ROLE_ARN" \
  --type STANDARD \
  --region "$EKS_REGION_B" >/dev/null 2>&1 || true

aws eks associate-access-policy \
  --cluster-name "$EKS_CLUSTER_NAME_B" \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region "$EKS_REGION_B" >/dev/null 2>&1 || true

for i in 1 2 3 4 5; do
  kubectl --kubeconfig "$KUBECONFIG" get ns >/dev/null 2>&1 && break
  sleep 3
done

kubectl --kubeconfig "$KUBECONFIG" -n chatbot create secret generic starai-db-secret \
  --from-literal=MONGO_URI="$MONGO_URI" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG" apply -f -

kubectl --kubeconfig "$KUBECONFIG" -n chatbot create secret generic openai-secret \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG" apply -f -
