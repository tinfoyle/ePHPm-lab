#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE=wordpress-v5

run_lane() {
  local deployment="$1"
  local service="$2"
  local label="$3"
  local others=""

  case "${deployment}" in
    wordpress-v5-php-fpm) others="wordpress-v5-ephpm wordpress-v5-ephpm-worker" ;;
    wordpress-v5-ephpm) others="wordpress-v5-php-fpm wordpress-v5-ephpm-worker" ;;
    wordpress-v5-ephpm-worker) others="wordpress-v5-php-fpm wordpress-v5-ephpm" ;;
  esac

  kubectl scale deployment ${others} -n "${NAMESPACE}" --replicas=0
  kubectl scale deployment/"${deployment}" -n "${NAMESPACE}" --replicas=1
  kubectl rollout status deployment/"${deployment}" -n "${NAMESPACE}" --timeout=1200s

  run_k6 "k6-v5-cart-${label}" "${service}" wordpress-v5-k6-cart cart-integrity.js 180
  run_k6 "k6-v5-browse-${label}" "${service}" wordpress-v5-k6-browse browse.js 240
}

run_k6() {
  local job="$1"
  local service="$2"
  local config_map="$3"
  local script="$4"
  local timeout="$5"

  kubectl delete job "${job}" -n "${NAMESPACE}" --ignore-not-found
  cat <<EOF | kubectl apply -f -
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
              value: http://${service}:8080
          command: ["k6", "run", "/scripts/${script}"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: ${config_map}
EOF
  kubectl wait --for=condition=complete "job/${job}" -n "${NAMESPACE}" --timeout="${timeout}s"
  kubectl logs "job/${job}" -n "${NAMESPACE}"
}

"${ROOT}/scripts/apply-wordpress-v5.sh"
kubectl rollout status deployment/wordpress-v5-mysql -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/wordpress-v5-redis -n "${NAMESPACE}" --timeout=300s

run_lane wordpress-v5-php-fpm wordpress-v5-php-fpm php-fpm
run_lane wordpress-v5-ephpm wordpress-v5-ephpm ephpm
run_lane wordpress-v5-ephpm-worker wordpress-v5-ephpm-worker ephpm-worker
