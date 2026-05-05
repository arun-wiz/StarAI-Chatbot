#!/usr/bin/env bash
set -euo pipefail

exec bash "$(dirname "$0")/deploy_aws_eks.sh" "$@"
