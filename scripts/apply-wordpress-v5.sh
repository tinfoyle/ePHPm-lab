#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE=wordpress-v5

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create configmap wordpress-v5-scripts \
  --from-file=prepare-wordpress.sh="${ROOT}/wordpress-v5/scripts/prepare-wordpress.sh" \
  --from-file=install-wordpress-worker.sh="${ROOT}/wordpress-v5/scripts/install-wordpress-worker.sh" \
  --from-file=php-fpm-start.sh="${ROOT}/wordpress-v5/scripts/php-fpm-start.sh" \
  --from-file=ephpm-start.sh="${ROOT}/wordpress-v5/scripts/ephpm-start.sh" \
  --from-file=ephpm-worker-start.sh="${ROOT}/wordpress-v5/scripts/ephpm-worker-start.sh" \
  --from-file=v5-benchmark.php="${ROOT}/wordpress-v5/scripts/v5-benchmark.php" \
  --from-file=seed.php="${ROOT}/wordpress-v5/scripts/seed.php" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create configmap wordpress-v5-k6-browse \
  --from-file=browse.js="${ROOT}/wordpress-v5/k6/browse.js" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create configmap wordpress-v5-k6-cart \
  --from-file=cart-integrity.js="${ROOT}/wordpress-v5/k6/cart-integrity.js" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${ROOT}/k8s/wordpress-v5.yaml"
