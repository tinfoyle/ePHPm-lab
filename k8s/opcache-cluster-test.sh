#!/usr/bin/env bash
# PRE/POST test for cluster-wide OPcache invalidation (opcache-cluster.yaml).
#
# Flow:
#   1. PRE   — warm opcache_target.php on both pods, assert it is cached on both
#   2. DEPLOY — `ephpm deploy` on pod-0 only (one KV write, gossip fans out)
#   3. POST  — both pods drop the cache entry on their next request,
#              including pod-1 which never saw the deploy command
#
# Requests are made in-pod via `ephpm php -r 'file_get_contents(...)'` so no
# curl is needed inside the image. Requires: kubectl, jq.
set -euo pipefail

NS=opcache-demo
PODS=(opcache-demo-0 opcache-demo-1)

req() { # req <pod> <path>  -> body
  kubectl -n "$NS" exec "$1" -c ephpm -- \
    ephpm php -r "echo file_get_contents('http://127.0.0.1:8080$2');"
}

status_field() { # status_field <pod> <jq-expr>
  req "$1" /opcache_status.php | jq -r "$2"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> waiting for both pods to be Ready"
kubectl -n "$NS" rollout status statefulset/opcache-demo --timeout=300s

echo "==> sanity: OPcache active on both pods"
for pod in "${PODS[@]}"; do
  enabled=$(status_field "$pod" .opcache_enabled)
  [ "$enabled" = "true" ] || fail "$pod: opcache_enabled=$enabled (need an ephpm >= 0.4.0 image)"
done

echo "==> PRE: warm the target script on both pods"
for pod in "${PODS[@]}"; do
  req "$pod" /opcache_target.php >/dev/null
  cached=$(status_field "$pod" .target_cached)
  [ "$cached" = "true" ] || fail "$pod: target not cached after warm-up"
  echo "    $pod: target_cached=true"
done

echo "==> DEPLOY: single 'ephpm deploy' on ${PODS[0]} (writes opcache:version:_default)"
kubectl -n "$NS" exec "${PODS[0]}" -c ephpm -- ephpm deploy

echo "==> POST: both pods must drop the entry on their next request"
for pod in "${PODS[@]}"; do
  dropped=""
  # Gossip converges in ~1-5s; each status request is itself a PHP request,
  # so it triggers the per-request watcher on that pod.
  for _ in $(seq 1 15); do
    cached=$(status_field "$pod" .target_cached)
    if [ "$cached" = "false" ]; then dropped=1; break; fi
    sleep 2
  done
  [ -n "$dropped" ] || fail "$pod: cache entry not dropped within 30s of deploy"
  echo "    $pod: entry dropped"
done

echo "==> RE-WARM: next hit recompiles and re-caches"
for pod in "${PODS[@]}"; do
  req "$pod" /opcache_target.php >/dev/null
  cached=$(status_field "$pod" .target_cached)
  [ "$cached" = "true" ] || fail "$pod: target not re-cached after invalidation"
  echo "    $pod: re-cached"
done

echo "PASS: one deploy on ${PODS[0]} invalidated OPcache on ${PODS[*]}"
