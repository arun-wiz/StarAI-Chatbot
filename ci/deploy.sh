#!/usr/bin/env bash
set -euo pipefail

# Required env:
# EKS_CLUSTER_NAME, EKS_REGION
# REPO_DIR (optional), IMG_TAG (computed earlier), ECR_IMAGE, ECR_IMAGE_TAGGED
# PUBLIC_DOMAIN (from env), ALB_ACM_ARN (from env)
# FLOW_ID (or overridden in your Jenkinsfile before calling this)
# DEMO_MODE (true/false) - if true, deploys HTTP-only ingress without host/cert

EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-${EKS_CLUSTER_NAME_B:-}}"
EKS_REGION="${EKS_REGION:-${EKS_REGION_B:-}}"
: "${EKS_CLUSTER_NAME:?missing}"
: "${EKS_REGION:?missing}"
DEMO_MODE="${DEMO_MODE:-false}"
: "${LANGFLOW_SEED_IMAGE:?missing}"

echo "[INFO] Setting kubeconfig for ${EKS_CLUSTER_NAME} (${EKS_REGION})..."
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}" --kubeconfig .kubeconfig
export KUBECONFIG="$(pwd)/.kubeconfig"

# Render manifests
DEPLOY_FILE="manifests/deployment.yaml"
CFG_FILE="manifests/configmap.yaml"
ING_FILE_CUSTOM="manifests/ingress.yaml"
ING_FILE_DEMO="manifests/ingress-demo.yaml"

echo "[INFO] Using image: ${ECR_IMAGE_TAGGED}"
sed -i "s#879381248241.dkr.ecr.us-east-1.amazonaws.com/starai-chatbot:latest#${ECR_IMAGE_TAGGED}#g" "${DEPLOY_FILE}"

echo "[INFO] Using Langflow seed image: ${LANGFLOW_SEED_IMAGE}"
sed -i "s#docker.io/REPLACE_LANGFLOW_SEED_IMAGE#docker.io/${LANGFLOW_SEED_IMAGE}#g" "${DEPLOY_FILE}"

if [[ -n "${FLOW_ID:-}" && "${FLOW_ID}" != "REPLACE_WITH_YOUR_FLOW_ID" ]]; then
  sed -i "s#FLOW_ID: \"REPLACE_WITH_YOUR_FLOW_ID\"#FLOW_ID: \"${FLOW_ID}\"#g" "${CFG_FILE}"
fi

if [[ "${DEMO_MODE}" != "true" ]]; then
  if [[ -n "${PUBLIC_DOMAIN:-}" ]]; then
    sed -i "s#your-domain.example.com#${PUBLIC_DOMAIN}#g" "${ING_FILE_CUSTOM}"
  fi
  if [[ -n "${ALB_ACM_ARN:-}" ]]; then
    sed -i "s#arn:aws:acm:us-east-1:879381248241:certificate/REPLACE_ME#${ALB_ACM_ARN}#g" "${ING_FILE_CUSTOM}"
  fi
fi

# Apply manifests (namespace -> pvc -> config -> deployment -> service -> ingress)
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/storageclass-efs.yaml
kubectl -n chatbot apply -f manifests/pvc.yaml
kubectl -n chatbot apply -f manifests/configmap.yaml
kubectl -n chatbot apply -f manifests/serviceaccount.yaml
kubectl -n chatbot apply -f manifests/clusterrolebinding.yaml
kubectl -n chatbot apply -f manifests/deployment.yaml
kubectl -n chatbot apply -f manifests/service.yaml
if [[ "${DEMO_MODE}" == "true" ]]; then
  kubectl -n chatbot apply -f "${ING_FILE_DEMO}"
else
  kubectl -n chatbot apply -f "${ING_FILE_CUSTOM}"
fi

echo "[INFO] Waiting for rollout..."
kubectl -n chatbot rollout status deploy/chatbot --timeout=180s

if [[ "${DEMO_MODE}" == "true" ]]; then
  echo "[INFO] Waiting for ALB hostname (Ingress) ..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ALB_HOSTNAME="$(kubectl -n chatbot get ingress chatbot -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "${ALB_HOSTNAME}" ]]; then
      echo "[INFO] ALB DNS: ${ALB_HOSTNAME}"
      echo "[INFO] Demo URL: http://${ALB_HOSTNAME}/"
      break
    fi
    sleep 6
  done
fi
