#!/usr/bin/env bash
set -euo pipefail

: "${GAR_IMAGE_TAGGED:?missing}"
: "${GCP_PROJECT_ID:?missing}"
: "${GKE_CLUSTER_NAME:?missing}"
: "${GKE_LOCATION:?missing}"

K8S_NAMESPACE="${K8S_NAMESPACE:-chatbot}"
DEMO_MODE="${DEMO_MODE:-true}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
MANAGED_CERT_NAME="${MANAGED_CERT_NAME:-chatbot-managed-cert}"
GKE_STATIC_IP_NAME="${GKE_STATIC_IP_NAME:-}"
LANGFLOW_SEED_IMAGE="${LANGFLOW_SEED_IMAGE:-}"
FLOW_ID="${FLOW_ID:-}"

export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"

if ! kubectl --kubeconfig "${KUBECONFIG}" cluster-info >/dev/null 2>&1; then
  echo "[INFO] Fetching GKE credentials for ${GKE_CLUSTER_NAME} (${GKE_LOCATION})..."
  gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" \
    --location "${GKE_LOCATION}" \
    --project "${GCP_PROJECT_ID}" \
    --kubeconfig "${KUBECONFIG}"
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

copy_manifest() {
  cp "$1" "${tmp_dir}/$2"
}

replace_all() {
  local pattern="$1"
  local value="$2"
  local file="$3"
  sed -i.bak "s#${pattern}#${value}#g" "${file}"
  rm -f "${file}.bak"
}

set_config_value() {
  local key="$1"
  local value="${2:-}"
  local file="${tmp_dir}/configmap.yaml"
  if [[ -z "${value}" ]]; then
    return
  fi

  if grep -qE "^[[:space:]]*${key}:" "${file}"; then
    sed -i.bak -E "s#^([[:space:]]*${key}:)[[:space:]]*.*#\\1 \"${value}\"#" "${file}"
    rm -f "${file}.bak"
  else
    sed -i.bak "/^data:/a\\  ${key}: \"${value}\"" "${file}"
    rm -f "${file}.bak"
  fi
}

set_manifest_namespace() {
  local file="$1"
  replace_all "namespace: chatbot" "namespace: ${K8S_NAMESPACE}" "${file}"
}

set_namespace_name() {
  local file="$1"
  replace_all "name: chatbot" "name: ${K8S_NAMESPACE}" "${file}"
}

if [[ -n "${LANGFLOW_SEED_IMAGE}" ]]; then
  copy_manifest manifests/deployment.yaml deployment.yaml
else
  copy_manifest manifests/deployment-noseed.yaml deployment.yaml
fi
copy_manifest manifests/namespace.yaml namespace.yaml
copy_manifest manifests/configmap.yaml configmap.yaml
copy_manifest manifests/pvc-gke.yaml pvc.yaml
copy_manifest manifests/service-gke.yaml service.yaml
copy_manifest manifests/serviceaccount.yaml serviceaccount.yaml
copy_manifest manifests/clusterrolebinding.yaml clusterrolebinding.yaml

replace_all "REPLACE_ECR_IMAGE" "${GAR_IMAGE_TAGGED}" "${tmp_dir}/deployment.yaml"

if [[ -n "${LANGFLOW_SEED_IMAGE}" ]]; then
  replace_all "docker.io/REPLACE_LANGFLOW_SEED_IMAGE" "${LANGFLOW_SEED_IMAGE}" "${tmp_dir}/deployment.yaml"
fi

if [[ -n "${FLOW_ID}" && "${FLOW_ID}" != "REPLACE_WITH_YOUR_FLOW_ID" ]]; then
  set_config_value "FLOW_ID" "${FLOW_ID}"
fi

set_config_value "AGENT_PROVIDER" "${AGENT_PROVIDER:-}"
set_config_value "AGENT_STORAGE_PROVIDER" "${AGENT_STORAGE_PROVIDER:-}"
set_config_value "AGENT_PII_BUCKET" "${AGENT_PII_BUCKET:-}"
set_config_value "AGENT_CUSTOMER_OBJECT" "${AGENT_CUSTOMER_OBJECT:-}"
set_config_value "AGENT_PAYMENTS_OBJECT" "${AGENT_PAYMENTS_OBJECT:-}"
set_config_value "AGENT_DEMO_UNSAFE" "${AGENT_DEMO_UNSAFE:-}"
set_config_value "AWS_REGION" "${AWS_REGION:-}"
set_config_value "BEDROCK_MODEL_ID" "${BEDROCK_MODEL_ID:-}"
set_config_value "BEDROCK_AGENT_ID" "${BEDROCK_AGENT_ID:-}"
set_config_value "BEDROCK_AGENT_ALIAS_ID" "${BEDROCK_AGENT_ALIAS_ID:-}"
set_config_value "VERTEX_PROJECT_ID" "${VERTEX_PROJECT_ID:-${GCP_PROJECT_ID}}"
set_config_value "VERTEX_LOCATION" "${VERTEX_LOCATION:-${GKE_LOCATION}}"
set_config_value "VERTEX_MODEL_ID" "${VERTEX_MODEL_ID:-}"

if [[ "${DEMO_MODE}" == "true" ]]; then
  copy_manifest manifests/ingress-gke-demo.yaml ingress.yaml
else
  : "${PUBLIC_DOMAIN:?public_domain is required when demo_mode=false}"
  copy_manifest manifests/managedcertificate.yaml managedcertificate.yaml
  copy_manifest manifests/ingress-gke.yaml ingress.yaml
  replace_all "REPLACE_PUBLIC_DOMAIN" "${PUBLIC_DOMAIN}" "${tmp_dir}/managedcertificate.yaml"
  replace_all "REPLACE_MANAGED_CERT_NAME" "${MANAGED_CERT_NAME}" "${tmp_dir}/managedcertificate.yaml"
  replace_all "REPLACE_PUBLIC_DOMAIN" "${PUBLIC_DOMAIN}" "${tmp_dir}/ingress.yaml"
  replace_all "REPLACE_MANAGED_CERT_NAME" "${MANAGED_CERT_NAME}" "${tmp_dir}/ingress.yaml"

  if [[ -n "${GKE_STATIC_IP_NAME}" ]]; then
    replace_all "# REPLACE_GKE_STATIC_IP_ANNOTATION" "kubernetes.io/ingress.global-static-ip-name: ${GKE_STATIC_IP_NAME}" "${tmp_dir}/ingress.yaml"
  else
    sed -i.bak "/REPLACE_GKE_STATIC_IP_ANNOTATION/d" "${tmp_dir}/ingress.yaml"
    rm -f "${tmp_dir}/ingress.yaml.bak"
  fi
fi

set_namespace_name "${tmp_dir}/namespace.yaml"
set_manifest_namespace "${tmp_dir}/serviceaccount.yaml"
set_manifest_namespace "${tmp_dir}/clusterrolebinding.yaml"
set_manifest_namespace "${tmp_dir}/pvc.yaml"
set_manifest_namespace "${tmp_dir}/configmap.yaml"
set_manifest_namespace "${tmp_dir}/deployment.yaml"
set_manifest_namespace "${tmp_dir}/service.yaml"
set_manifest_namespace "${tmp_dir}/ingress.yaml"

replace_all "name: chatbot-admin-clusterrolebinding" "name: ${K8S_NAMESPACE}-chatbot-admin-clusterrolebinding" "${tmp_dir}/clusterrolebinding.yaml"

if [[ "${DEMO_MODE}" != "true" ]]; then
  set_manifest_namespace "${tmp_dir}/managedcertificate.yaml"
fi

kubectl apply -f "${tmp_dir}/namespace.yaml"
kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/serviceaccount.yaml"
if [[ -n "${GCP_AGENT_SERVICE_ACCOUNT:-}" ]]; then
  kubectl -n "${K8S_NAMESPACE}" annotate serviceaccount chatbot-admin \
    iam.gke.io/gcp-service-account="${GCP_AGENT_SERVICE_ACCOUNT}" \
    --overwrite
fi
kubectl apply -f "${tmp_dir}/clusterrolebinding.yaml"
kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/pvc.yaml"
kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/configmap.yaml"
kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/deployment.yaml"
kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/service.yaml"

if [[ "${DEMO_MODE}" != "true" ]]; then
  kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/managedcertificate.yaml"
fi

kubectl -n "${K8S_NAMESPACE}" apply -f "${tmp_dir}/ingress.yaml"

echo "[INFO] Waiting for rollout..."
kubectl -n "${K8S_NAMESPACE}" rollout status deploy/chatbot --timeout=240s

echo "[INFO] Waiting for GKE ingress IP..."
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  INGRESS_IP="$(kubectl -n "${K8S_NAMESPACE}" get ingress chatbot -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${INGRESS_IP}" ]]; then
    echo "[INFO] GKE ingress IP: ${INGRESS_IP}"
    if [[ "${DEMO_MODE}" == "true" ]]; then
      echo "[INFO] Demo URL: http://${INGRESS_IP}/"
    else
      echo "[INFO] Point ${PUBLIC_DOMAIN} at ${INGRESS_IP} if DNS is not already configured."
      kubectl -n "${K8S_NAMESPACE}" get managedcertificate "${MANAGED_CERT_NAME}" || true
    fi
    exit 0
  fi
  sleep 15
done

echo "[WARN] Ingress IP was not assigned within the wait window."
