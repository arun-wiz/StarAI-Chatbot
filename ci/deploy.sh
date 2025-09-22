#!/usr/bin/env bash
set -euo pipefail

# Required env:
# EKS_CLUSTER_NAME_B, EKS_REGION_B
# REPO_DIR (optional), IMG_TAG (computed earlier), ECR_IMAGE, ECR_IMAGE_TAGGED
# PUBLIC_DOMAIN (from env), ALB_ACM_ARN (from env)
# FLOW_ID (or overridden in your Jenkinsfile before calling this)

echo "[INFO] Setting kubeconfig for ${EKS_CLUSTER_NAME_B} (${EKS_REGION_B})..."
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME_B}" --region "${EKS_REGION_B}" --kubeconfig .kubeconfig
export KUBECONFIG="$(pwd)/.kubeconfig"

# Render manifests
DEPLOY_FILE="manifests/deployment.yaml"
CFG_FILE="manifests/configmap.yaml"
ING_FILE="manifests/ingress.yaml"

echo "[INFO] Using image: ${ECR_IMAGE_TAGGED}"
sed -i "s#879381248241.dkr.ecr.us-east-1.amazonaws.com/starai-dashboard:latest#${ECR_IMAGE_TAGGED}#g" "${DEPLOY_FILE}"

if [[ -n "${FLOW_ID:-}" && "${FLOW_ID}" != "REPLACE_WITH_YOUR_FLOW_ID" ]]; then
  sed -i "s#FLOW_ID: \"REPLACE_WITH_YOUR_FLOW_ID\"#FLOW_ID: \"${FLOW_ID}\"#g" "${CFG_FILE}"
fi

if [[ -n "${PUBLIC_DOMAIN:-}" ]]; then
  sed -i "s#your-domain.example.com#${PUBLIC_DOMAIN}#g" "${ING_FILE}"
fi
if [[ -n "${ALB_ACM_ARN:-}" ]]; then
  sed -i "s#arn:aws:acm:us-east-1:879381248241:certificate/REPLACE_ME#${ALB_ACM_ARN}#g" "${ING_FILE}"
fi

# Apply manifests (namespace -> pvc -> config -> deployment -> service -> ingress)
kubectl apply -f manifests/namespace.yaml
kubectl -n chatbot apply -f manifests/pvc.yaml
kubectl -n chatbot apply -f manifests/configmap.yaml
kubectl -n chatbot apply -f manifests/deployment.yaml
kubectl -n chatbot apply -f manifests/service.yaml
kubectl -n chatbot apply -f manifests/alb-ingress.yaml

echo "[INFO] Waiting for rollout..."
kubectl -n chatbot rollout status deploy/chatbot --timeout=180s
