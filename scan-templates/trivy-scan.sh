#!/bin/bash
set -euo pipefail

# Usage:
#   ./trivy-scan.sh                      # scans the image built by Kaniko (reads pushed.digest)
#   ./trivy-scan.sh <image-ref> <dir>    # scans an explicit image, writes report to <dir>

IMAGE_ARG="${1:-}"
REPORT_DIR_ARG="${2:-}"

: "${TRIVY_CACHE_DIR:=/root/.cache/trivy}"
mkdir -p reports

if [[ -n "${IMAGE_ARG}" ]]; then
  IMG_REF="${IMAGE_ARG}"
  OUT_DIR="${REPORT_DIR_ARG:-reports/trivy-image}"
else
  DIGEST_FILE="pushed.digest"
  [[ -f "${DIGEST_FILE}" ]] || DIGEST_FILE="/img-out/pushed.digest"
  [[ -f "${DIGEST_FILE}" ]] || { echo "[ERROR] Digest file not found"; exit 1; }

  ECR_REPO_REF="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPO}"

  echo "[INFO] Using digest file: ${DIGEST_FILE}"
  nl -ba "${DIGEST_FILE}" || true

  ECR_LINE="$(grep -E "^${ECR_REPO_REF}(@|:)" "${DIGEST_FILE}" | head -n1 || true)"
  [[ -n "${ECR_LINE}" ]] || { echo "[ERROR] Could not find ECR line for ${ECR_REPO_REF}"; exit 1; }

  IMG_REF="$(printf "%s\n" "${ECR_LINE}" | sed -E 's/:([^@]+)@/@/')"
  OUT_DIR="reports/trivy-image"
fi

echo "[INFO] Scanning ${IMG_REF}"
mkdir -p "${OUT_DIR}"
cp -f scan-templates/trivy-report.css "${OUT_DIR}/" || true

# ADVISORY-ONLY: do not fail build on findings
trivy image \
  --scanners vuln,secret \
  --exit-code 0 \
  --no-progress \
  --cache-dir "${TRIVY_CACHE_DIR}" \
  --format template \
  --template "@scan-templates/trivy-image-csp.html.tpl" \
  --output "${OUT_DIR}/index.html" \
  "${IMG_REF}" || true

echo "[INFO] Report written to ${OUT_DIR}/index.html"
