#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EPHPM_SOURCE_IMAGE="${EPHPM_SOURCE_IMAGE:-}"

if [ -z "${EPHPM_SOURCE_IMAGE}" ]; then
  echo "Set EPHPM_SOURCE_IMAGE to the image that your Kubernetes cluster can pull." >&2
  echo "Example: EPHPM_SOURCE_IMAGE=ghcr.io/your-org/ephpm:source-469c51e scripts/render-laravel-v4.sh" >&2
  exit 1
fi

mkdir -p "${ROOT}/.generated/k8s"
sed "s#REPLACE_WITH_YOUR_EPHPM_SOURCE_IMAGE#${EPHPM_SOURCE_IMAGE}#g" \
  "${ROOT}/k8s/laravel-v4.yaml" > "${ROOT}/.generated/k8s/laravel-v4.yaml"

echo "${ROOT}/.generated/k8s/laravel-v4.yaml"

