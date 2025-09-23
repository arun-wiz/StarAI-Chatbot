#!/bin/sh
set -eu

# Usage:
#   ./trivy-scan.sh                      # scan image from pushed.digest
#   ./trivy-scan.sh <image-ref> <dir>    # scan explicit image into <dir>

IMAGE_ARG="${1:-}"
REPORT_DIR_ARG="${2:-}"

# Defaults if not provided by Jenkins env
: "${TRIVY_CACHE_DIR:=/root/.cache/trivy}"
: "${ECR_ACCOUNT:=}"
: "${ECR_REGION:=}"
: "${ECR_REPO:=}"

mkdir -p reports

if [ -n "${IMAGE_ARG}" ]; then
  IMG_REF="${IMAGE_ARG}"
  OUT_DIR="${REPORT_DIR_ARG:-reports/trivy-image}"
else
  # locate digest file either in workspace or shared /img-out
  DIGEST_FILE="pushed.digest"
  if [ ! -f "${DIGEST_FILE}" ]; then
    DIGEST_FILE="/img-out/pushed.digest"
  fi
  if [ ! -f "${DIGEST_FILE}" ]; then
    echo "[ERROR] Digest file not found" >&2
    exit 1
  fi

  if [ -z "${ECR_ACCOUNT}" ] || [ -z "${ECR_REGION}" ] || [ -z "${ECR_REPO}" ]; then
    echo "[ERROR] ECR_ACCOUNT/ECR_REGION/ECR_REPO not set in environment" >&2
    exit 1
  fi

  ECR_REPO_REF="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPO}"

  echo "[INFO] Using digest file: ${DIGEST_FILE}"
  if command -v nl >/dev/null 2>&1; then
    nl -ba "${DIGEST_FILE}" || true
  else
    cat -n "${DIGEST_FILE}" || true
  fi

  # first ECR line; allow either "...@sha256" or ":tag@sha256"
  ECR_LINE="$(grep -E "^${ECR_REPO_REF}(@|:)" "${DIGEST_FILE}" | head -n 1 || true)"
  if [ -z "${ECR_LINE}" ]; then
    echo "[ERROR] Could not find ECR line for ${ECR_REPO_REF}" >&2
    exit 1
  fi

  # normalize ":tag@sha256" → "@sha256" using basic sed (no -E)
  IMG_REF=$(printf "%s\n" "${ECR_LINE}" | sed 's/:[^@]*@/@/')
  OUT_DIR="reports/trivy-image"
fi

echo "[INFO] Scanning ${IMG_REF}"
mkdir -p "${OUT_DIR}"
cp -f scan-templates/trivy-report.css "${OUT_DIR}/" 2>/dev/null || true

# Advisory only: never fail build on findings or hiccups
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
