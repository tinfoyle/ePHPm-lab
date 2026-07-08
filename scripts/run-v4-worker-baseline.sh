#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-laravel-v4}"
KUBECTL="${KUBECTL:-kubectl}"

MANIFEST="${ROOT}/.generated/k8s/laravel-v4.yaml"
if [ ! -f "${MANIFEST}" ]; then
  echo "Missing ${MANIFEST}. Run scripts/render-laravel-v4.sh first." >&2
  exit 1
fi

"${KUBECTL}" apply -f "${MANIFEST}"
"${KUBECTL}" rollout status deployment/laravel-v4-php-fpm -n "${NAMESPACE}" --timeout=300s
"${KUBECTL}" rollout status deployment/laravel-v4-ephpm-worker -n "${NAMESPACE}" --timeout=300s

"${KUBECTL}" delete job k6-v4-ephpm-worker k6-v4-php-fpm -n "${NAMESPACE}" --ignore-not-found
"${KUBECTL}" apply -f "${ROOT}/k8s/k6-v4-php-fpm.yaml"
"${KUBECTL}" wait --for=condition=complete job/k6-v4-php-fpm -n "${NAMESPACE}" --timeout=300s
"${KUBECTL}" logs job/k6-v4-php-fpm -n "${NAMESPACE}"

"${KUBECTL}" delete job k6-v4-ephpm-worker -n "${NAMESPACE}" --ignore-not-found
"${KUBECTL}" apply -f "${ROOT}/k8s/k6-v4-ephpm-worker.yaml"
"${KUBECTL}" wait --for=condition=complete job/k6-v4-ephpm-worker -n "${NAMESPACE}" --timeout=300s
"${KUBECTL}" logs job/k6-v4-ephpm-worker -n "${NAMESPACE}"

