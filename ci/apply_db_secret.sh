#!/usr/bin/env bash
set -euo pipefail

exec bash "$(dirname "$0")/apply_aws_eks_secrets.sh" "$@"
