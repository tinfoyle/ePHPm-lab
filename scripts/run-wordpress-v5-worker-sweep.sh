#!/usr/bin/env bash
set -euo pipefail

# Run the plugin-heavy WordPress worker lane through a small capacity matrix.
# It deliberately keeps one app deployment active and records sampled metrics
# alongside each k6 log, rather than trying to infer saturation from latency.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-wordpress-v5}"
DURATION="${DURATION:-120s}"
RATES="${RATES:-2 4 6 8}"
WORKER_COUNTS="${WORKER_COUNTS:-2 4 6}"
RESULTS_DIR="${RESULTS_DIR:-${ROOT}/.generated/wordpress-v5-worker-sweep-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "${RESULTS_DIR}"
bash "${ROOT}/scripts/apply-wordpress-v5.sh"
kubectl -n "${NAMESPACE}" scale deployment/wordpress-v5-ephpm-worker --replicas=1

for workers in ${WORKER_COUNTS}; do
  kubectl -n "${NAMESPACE}" set env deployment/wordpress-v5-ephpm-worker "WORKER_COUNT=${workers}"
  kubectl -n "${NAMESPACE}" rollout restart deployment/wordpress-v5-ephpm-worker
  kubectl -n "${NAMESPACE}" rollout status deployment/wordpress-v5-ephpm-worker --timeout=20m

  for rate in ${RATES}; do
    run_id="w${workers}-r${rate}"
    run_dir="${RESULTS_DIR}/${run_id}"
    job="k6-v5-worker-${run_id}-$(date +%s)"
    mkdir -p "${run_dir}"

    cat > "${run_dir}/job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.53.0
          env:
            - name: BASE_URL
              value: http://wordpress-v5-ephpm-worker:8080
            - name: RATE
              value: "${rate}"
            - name: DURATION
              value: "${DURATION}"
          command: ["k6", "run", "/scripts/browse.js"]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 500m, memory: 256Mi}
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: wordpress-v5-k6-browse
EOF

    kubectl apply -f "${run_dir}/job.yaml"
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod" -l "job-name=${job}" --timeout=90s
    pod="$(kubectl -n "${NAMESPACE}" get pod -l "job-name=${job}" -o jsonpath='{.items[0].metadata.name}')"
    worker_pod="$(kubectl -n "${NAMESPACE}" get pod -l app=wordpress-v5-ephpm-worker -o jsonpath='{.items[0].metadata.name}')"
    worker_node="$(kubectl -n "${NAMESPACE}" get pod "${worker_pod}" -o jsonpath='{.spec.nodeName}')"

    (
      while kubectl -n "${NAMESPACE}" get pod "${pod}" >/dev/null 2>&1; do
        date -Is
        kubectl -n "${NAMESPACE}" top pod "${worker_pod}" --no-headers || true
        kubectl top node "${worker_node}" --no-headers || true
        sleep 10
      done
    ) > "${run_dir}/metrics.txt" 2>&1 &
    sampler_pid=$!

    set +e
    wait_status=1
    for _ in $(seq 1 360); do
      succeeded="$(kubectl -n "${NAMESPACE}" get job "${job}" -o jsonpath='{.status.succeeded}')"
      failed="$(kubectl -n "${NAMESPACE}" get job "${job}" -o jsonpath='{.status.failed}')"
      if [ "${succeeded}" = "1" ]; then
        wait_status=0
        break
      fi
      if [ "${failed}" = "1" ]; then
        break
      fi
      sleep 1
    done
    set -e
    kill "${sampler_pid}" 2>/dev/null || true
    wait "${sampler_pid}" 2>/dev/null || true

    kubectl -n "${NAMESPACE}" logs "job/${job}" > "${run_dir}/k6.txt" || true
    kubectl -n "${NAMESPACE}" logs deployment/wordpress-v5-ephpm-worker --tail=500 > "${run_dir}/worker.log" || true
    kubectl -n "${NAMESPACE}" get job "${job}" -o yaml > "${run_dir}/job-result.yaml"
    printf 'workers=%s\nrate=%s\nduration=%s\nwait_status=%s\n' "${workers}" "${rate}" "${DURATION}" "${wait_status}" > "${run_dir}/run.txt"
  done
done

printf 'Results written to %s\n' "${RESULTS_DIR}"
