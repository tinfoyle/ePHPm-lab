#!/usr/bin/env bash
# build-rr.sh — Build the RoadRunner benchmark image and load it into kind.
#
# Usage:
#   ./rr/build-rr.sh [--cluster-name <name>] [--tag <image-tag>]
#
# Defaults:
#   --cluster-name   ephpm-lab
#   --tag            bench-rr:local
#
# After this script completes, apply the stack:
#   kubectl apply -f k8s/runtimes-bench.yaml
#
# The Deployment uses imagePullPolicy: Never so kind reads the locally-loaded image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="ephpm-lab"
TAG="bench-rr:local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER="$2"; shift 2 ;;
    --tag)          TAG="$2";     shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "==> Building ${TAG} from rr/Dockerfile ..."
docker build -t "${TAG}" "${ROOT}/rr/"

echo "==> Loading ${TAG} into kind cluster '${CLUSTER}' ..."
kind load docker-image "${TAG}" --name "${CLUSTER}"

echo ""
echo "Done. Now apply the stack:"
echo "  kubectl apply -f k8s/runtimes-bench.yaml"
echo ""
echo "The bench-rr Deployment uses imagePullPolicy: Never and will use"
echo "the locally-loaded image without contacting a registry."
