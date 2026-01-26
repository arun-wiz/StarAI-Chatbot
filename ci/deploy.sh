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
LANGFLOW_SEED_IMAGE="${LANGFLOW_SEED_IMAGE:-}"

echo "[INFO] Setting kubeconfig for ${EKS_CLUSTER_NAME} (${EKS_REGION})..."
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}" --kubeconfig .kubeconfig
export KUBECONFIG="$(pwd)/.kubeconfig"

# Detect EKS Auto Mode vs standard EKS (affects StorageClass provisioner)
AUTO_MODE_ENABLED="false"
if aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}" --query 'cluster.computeConfig.enabled' --output text >/dev/null 2>&1; then
  compute_enabled="$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${EKS_REGION}" --query 'cluster.computeConfig.enabled' --output text 2>/dev/null || true)"
  if [[ "${compute_enabled}" == "True" || "${compute_enabled}" == "true" ]]; then
    AUTO_MODE_ENABLED="true"
  fi
fi

if [[ "${AUTO_MODE_ENABLED}" == "true" ]]; then
  echo "[INFO] Detected EKS Auto Mode cluster (computeConfig.enabled=true)"
  STORAGECLASS_FILE="manifests/storageclass-ebs-gp3-automode.yaml"
  DESIRED_PROVISIONER="ebs.csi.eks.amazonaws.com"
else
  echo "[INFO] Detected standard EKS cluster (Auto Mode disabled/not present)"
  STORAGECLASS_FILE="manifests/storageclass-ebs-gp3.yaml"
  DESIRED_PROVISIONER="ebs.csi.aws.com"
fi

# Render manifests
DEPLOY_FILE_SEEDED="manifests/deployment.yaml"
DEPLOY_FILE_NOSEED="manifests/deployment-noseed.yaml"
if [[ -n "${LANGFLOW_SEED_IMAGE}" ]]; then
  DEPLOY_FILE="${DEPLOY_FILE_SEEDED}"
else
  DEPLOY_FILE="${DEPLOY_FILE_NOSEED}"
fi
CFG_FILE="manifests/configmap.yaml"
ING_FILE_CUSTOM="manifests/ingress.yaml"
ING_FILE_DEMO="manifests/ingress-demo.yaml"

echo "[INFO] Using image: ${ECR_IMAGE_TAGGED}"
sed -i "s#REPLACE_ECR_IMAGE#${ECR_IMAGE_TAGGED}#g" "${DEPLOY_FILE}"

if [[ -n "${LANGFLOW_SEED_IMAGE}" ]]; then
  echo "[INFO] Using Langflow seed image: ${LANGFLOW_SEED_IMAGE}"
  sed -i "s#docker.io/REPLACE_LANGFLOW_SEED_IMAGE#docker.io/${LANGFLOW_SEED_IMAGE}#g" "${DEPLOY_FILE}"
else
  echo "[INFO] No Langflow seed image provided; Langflow will create a new /data/langflow.db"
fi

if [[ -n "${FLOW_ID:-}" && "${FLOW_ID}" != "REPLACE_WITH_YOUR_FLOW_ID" ]]; then
  sed -i -E "s#^(\s*FLOW_ID:)\s*.*#\1 \"${FLOW_ID}\"#" "${CFG_FILE}"
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
DESIRED_SC="ebs-gp3-sc"

# StorageClass provisioner is immutable; if it exists with the wrong provisioner, recreate it.
EXISTING_PROVISIONER="$(kubectl get storageclass "${DESIRED_SC}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
if [[ -n "${EXISTING_PROVISIONER}" && "${EXISTING_PROVISIONER}" != "${DESIRED_PROVISIONER}" ]]; then
  echo "[WARN] StorageClass '${DESIRED_SC}' provisioner is '${EXISTING_PROVISIONER}' (expected '${DESIRED_PROVISIONER}'). Recreating StorageClass..."
  kubectl delete storageclass "${DESIRED_SC}" --ignore-not-found
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kubectl get storageclass "${DESIRED_SC}" >/dev/null 2>&1 || break
    sleep 2
  done
fi
kubectl apply -f "${STORAGECLASS_FILE}"

EXISTING_SC="$(kubectl -n chatbot get pvc langflow-pvc -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
if [[ -n "${EXISTING_SC}" && "${EXISTING_SC}" != "${DESIRED_SC}" ]]; then
  echo "[WARN] langflow-pvc StorageClass is '${EXISTING_SC}' (expected '${DESIRED_SC}'). Recreating PVC..."
  kubectl -n chatbot delete pvc langflow-pvc --ignore-not-found
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kubectl -n chatbot get pvc langflow-pvc >/dev/null 2>&1 || break
    sleep 2
  done
fi

kubectl -n chatbot apply -f manifests/pvc.yaml
kubectl -n chatbot apply -f manifests/configmap.yaml
kubectl -n chatbot apply -f manifests/serviceaccount.yaml
kubectl -n chatbot apply -f manifests/clusterrolebinding.yaml
kubectl -n chatbot apply -f "${DEPLOY_FILE}"
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
