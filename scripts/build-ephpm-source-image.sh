#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EPHPM_DIR="${EPHPM_DIR:-${ROOT}/apps/ephpm}"
IMAGE="${IMAGE:-lke-lab/ephpm:source-469c51e}"
PHP_SDK_VERSION="${PHP_SDK_VERSION:-8.4.22}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

if [ ! -d "${EPHPM_DIR}" ]; then
  echo "Missing ${EPHPM_DIR}. Run scripts/clone-inputs.sh first." >&2
  exit 1
fi

docker build \
  -f "${EPHPM_DIR}/docker/Dockerfile" \
  --build-arg "PHP_SDK_VERSION=${PHP_SDK_VERSION}" \
  --build-arg "RUST_TOOLCHAIN=${RUST_TOOLCHAIN}" \
  -t "${IMAGE}" \
  "${EPHPM_DIR}"

echo "Built ${IMAGE}"
echo "For a remote Kubernetes cluster, push this image and use the pushed reference as EPHPM_SOURCE_IMAGE."

