#!/usr/bin/env bash
# run-runtimes-bench.sh
# Drive the five-way PHP runtime comparison benchmark in the runtimes-bench namespace.
#
# Usage:
#   ./scripts/run-runtimes-bench.sh [--no-apply] [--no-cleanup]
#
#   --no-apply     Skip initial kubectl apply (stack already deployed)
#   --no-cleanup   Leave k6 Jobs in place after the run (for log inspection)
#
# Prerequisites:
#   - kubectl context pointing at the lab cluster (set KUBECTL env to override)
#   - For RoadRunner: build and kind-load bench-rr:local first:
#       ./rr/build-rr.sh --cluster-name <your-cluster>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/k8s/runtimes-bench.yaml"
NS="runtimes-bench"
KUBECTL="${KUBECTL:-kubectl}"
APPLY=true
CLEANUP=true

for arg in "$@"; do
  case "$arg" in
    --no-apply)   APPLY=false ;;
    --no-cleanup) CLEANUP=false ;;
  esac
done

K6_JOBS=(k6-bench-ephpm k6-bench-nginx-fpm k6-bench-frankenphp k6-bench-swoole k6-bench-rr)
DEPLOYMENTS=(bench-ephpm bench-nginx-fpm bench-frankenphp bench-swoole bench-rr)

# ---------------------------------------------------------------------------
# 1. Deploy the stack; purge any auto-started k6 Jobs immediately
# ---------------------------------------------------------------------------
if $APPLY; then
  echo "==> Applying ${MANIFEST}"
  "${KUBECTL}" apply -f "${MANIFEST}"
  echo "==> Purging any auto-started k6 Jobs (will rerun after deployments are ready)"
  for job in "${K6_JOBS[@]}"; do
    "${KUBECTL}" delete job "${job}" -n "${NS}" --ignore-not-found
  done
fi

# ---------------------------------------------------------------------------
# 2. Wait for all five Deployments to become Ready
# ---------------------------------------------------------------------------
for d in "${DEPLOYMENTS[@]}"; do
  echo "==> Waiting for deployment/${d} ..."
  "${KUBECTL}" rollout status "deployment/${d}" -n "${NS}" --timeout=300s
done
echo "==> All five deployments ready."

# ---------------------------------------------------------------------------
# 3. Run k6 Jobs sequentially
#    We delete/recreate each Job individually so output is sequential and
#    easy to read; all five share the same bench-k6-script ConfigMap.
# ---------------------------------------------------------------------------
declare -A JOB_BASE_URL=(
  [k6-bench-ephpm]="http://bench-ephpm:8080"
  [k6-bench-nginx-fpm]="http://bench-nginx-fpm:8080"
  [k6-bench-frankenphp]="http://bench-frankenphp:8080"
  [k6-bench-swoole]="http://bench-swoole:8080"
  [k6-bench-rr]="http://bench-rr:8080"
)
declare -A JOB_HELLO_PATH=(
  [k6-bench-ephpm]="/hello.php"
  [k6-bench-nginx-fpm]="/hello.php"
  [k6-bench-frankenphp]="/hello.php"
  [k6-bench-swoole]="/hello"
  [k6-bench-rr]="/hello"
)
declare -A JOB_CPU_PATH=(
  [k6-bench-ephpm]="/cpu.php"
  [k6-bench-nginx-fpm]="/cpu.php"
  [k6-bench-frankenphp]="/cpu.php"
  [k6-bench-swoole]="/cpu"
  [k6-bench-rr]="/cpu"
)

for job in "${K6_JOBS[@]}"; do
  base_url="${JOB_BASE_URL[$job]}"
  hello_path="${JOB_HELLO_PATH[$job]}"
  cpu_path="${JOB_CPU_PATH[$job]}"

  echo ""
  echo "========================================================================"
  echo "  ${job}  ->  ${base_url}"
  echo "========================================================================"

  "${KUBECTL}" delete job "${job}" -n "${NS}" --ignore-not-found

  "${KUBECTL}" apply -f - <<JOBEOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: k6
        image: grafana/k6:0.53.0
        args:
        - run
        - -e
        - BASE_URL=${base_url}
        - -e
        - HELLO_PATH=${hello_path}
        - -e
        - CPU_PATH=${cpu_path}
        - -e
        - CONCURRENCY=16
        - -e
        - DURATION=30s
        - /scripts/bench.js
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "250m"
            memory: "256Mi"
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: scripts
        configMap:
          name: bench-k6-script
JOBEOF

  "${KUBECTL}" wait --for=condition=complete "job/${job}" -n "${NS}" --timeout=300s
  echo "--- ${job} ---"
  "${KUBECTL}" logs "job/${job}" -n "${NS}"
done

echo ""
echo "==> All k6 jobs complete."

# ---------------------------------------------------------------------------
# 4. Optional cleanup
# ---------------------------------------------------------------------------
if $CLEANUP; then
  echo "==> Removing k6 Jobs ..."
  for job in "${K6_JOBS[@]}"; do
    "${KUBECTL}" delete job "${job}" -n "${NS}" --ignore-not-found
  done
  echo "==> Deployments and Services left in place."
  echo "    Full teardown: kubectl delete namespace ${NS}"
fi
