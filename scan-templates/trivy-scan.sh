#!/bin/bash
set -euo pipefail

DIGEST_FILE="pushed.digest"
[ -f "${DIGEST_FILE}" ] || DIGEST_FILE="/img-out/pushed.digest"
[ -f "${DIGEST_FILE}" ] || { echo "[ERROR] Digest file not found"; exit 1; }

ECR_REPO_REF="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPO}"

echo "[INFO] Using digest file: ${DIGEST_FILE}"
echo "[INFO] Contents:"
nl -ba "${DIGEST_FILE}" || true

# Extract the ECR line (first match)
ECR_LINE=$(grep -E "^${ECR_REPO_REF}(@|:)" "${DIGEST_FILE}" | head -n1 || true)
if [ -z "${ECR_LINE}" ]; then
  echo "[ERROR] Could not find ECR line for ${ECR_REPO_REF} in ${DIGEST_FILE}"
  exit 1
fi

# Normalize repo:tag@sha256:… → repo@sha256:…
IMG_REF=$(printf "%s\n" "${ECR_LINE}" | sed -E 's/:([^@]+)@/@/')

echo "[INFO] Scanning ${IMG_REF}"
mkdir -p reports/trivy-image
cp -f scan-templates/trivy-report.css reports/trivy-image/ || true

trivy image \
  --scanners vuln,secret \
  --no-progress \
  --cache-dir "${TRIVY_CACHE_DIR}" \
  --format template \
  --template "@scan-templates/trivy-image-csp.html.tpl" \
  --output reports/trivy-image/index.html \
  "${IMG_REF}"
