#!/usr/bin/env bash
# A/B blip test: ePHPm cluster-wide OPcache invalidation vs php-fpm
# rolling-restart cache-bust, under identical live k6 load.
#
# Both stacks serve identical fixtures (30 include files + bench.php)
# via a 2-replica fleet in the opcache-demo namespace. k6 hits each stack
# at 50 iters/s for 120s; ~60s in we trigger the cache-bust:
#   - ephpm: `ephpm deploy` on one pod - gossip fans out, per-request
#            watcher on every node drops the vhost's opcache entries on
#            the very next request. No process restart. No dropped conns.
#   - fpm:   `kubectl rollout restart deployment/opcache-fpm` - the ONLY
#            real-world cache-bust when validate_timestamps=0. Each new
#            pod serves its first requests from a cold OPcache; in-flight
#            requests to a terminating pod may fail.
#
# Requires: kubectl, jq. ePHPm image must be >= v0.4.0.
set -euo pipefail

NS=opcache-demo
DIR="$(cd "$(dirname "$0")" && pwd)"
# kubectl on Windows/git-bash needs a Windows-style path.
if command -v cygpath >/dev/null 2>&1; then
  DIR="$(cygpath -w "$DIR")"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

apply_stacks() {
  echo "==> applying both stacks"
  kubectl apply -f "$DIR/opcache-cluster.yaml"
  kubectl apply -f "$DIR/opcache-fpm-cluster.yaml"
  kubectl apply -f "$DIR/k6-opcache-blip.yaml"
}

wait_ready() {
  echo "==> waiting for both stacks to be Ready"
  kubectl -n "$NS" rollout status statefulset/opcache-demo --timeout=300s
  kubectl -n "$NS" rollout status deployment/opcache-fpm --timeout=300s
}

warm_all() {
  echo "==> warming bench.php on every pod"
  local pods
  pods=$(kubectl -n "$NS" get pods -l app=opcache-demo -o jsonpath='{.items[*].metadata.name}')
  for p in $pods; do
    for _ in 1 2 3; do
      kubectl -n "$NS" exec "$p" -c ephpm -- \
        ephpm php -r "echo file_get_contents('http://127.0.0.1:8080/bench.php');" >/dev/null
    done
    echo "    $p: warm"
  done
  pods=$(kubectl -n "$NS" get pods -l app=opcache-fpm -o jsonpath='{.items[*].metadata.name}')
  for p in $pods; do
    for _ in 1 2 3; do
      kubectl -n "$NS" exec "$p" -c nginx -- \
        wget -qO- http://127.0.0.1:8080/bench.php >/dev/null 2>&1 || true
    done
    echo "    $p: warm"
  done
}

# reset_job <job-name>: delete + re-apply so we get a fresh run.
reset_job() {
  local job=$1
  kubectl -n "$NS" delete job "$job" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  # Re-apply just the whole k6 manifest; it's idempotent on ConfigMap +
  # the other job.
  kubectl apply -f "$DIR/k6-opcache-blip.yaml" >/dev/null
}

wait_for_job() {
  local job=$1
  local timeout=$2
  echo "==> waiting for $job to complete (up to ${timeout}s)"
  kubectl -n "$NS" wait --for=condition=complete "job/$job" --timeout="${timeout}s" \
    || fail "$job did not complete in ${timeout}s"
}

pod_of_job() {
  local job=$1
  kubectl -n "$NS" get pod -l "job-name=$job" -o jsonpath='{.items[0].metadata.name}'
}

extract_summary() {
  # Pull the JSON summary between our sentinels out of the pod logs.
  local pod=$1
  kubectl -n "$NS" logs "$pod" \
    | awk '/===K6-SUMMARY-BEGIN===/{f=1;next} /===K6-SUMMARY-END===/{f=0} f'
}

# --- ePHPm side --------------------------------------------------------
run_ephpm() {
  echo
  echo "======================================================"
  echo "  ePHPm run: cluster-wide OPcache invalidation via gossip"
  echo "======================================================"
  reset_job k6-blip-ephpm
  echo "==> k6 job started; sleeping 60s of warm traffic"
  sleep 60
  echo "==> mid-load: 'ephpm deploy' on opcache-demo-0 (one KV write)"
  kubectl -n "$NS" exec opcache-demo-0 -c ephpm -- ephpm deploy
  wait_for_job k6-blip-ephpm 180
  EPHPM_SUMMARY=$(extract_summary "$(pod_of_job k6-blip-ephpm)")
  [ -n "$EPHPM_SUMMARY" ] || fail "no k6 summary found in ephpm job logs"
}

# --- php-fpm side ------------------------------------------------------
run_fpm() {
  echo
  echo "======================================================"
  echo "  php-fpm run: rolling restart cache-bust"
  echo "======================================================"
  reset_job k6-blip-fpm
  echo "==> k6 job started; sleeping 60s of warm traffic"
  sleep 60
  echo "==> mid-load: 'kubectl rollout restart deployment/opcache-fpm'"
  kubectl -n "$NS" rollout restart deployment/opcache-fpm
  wait_for_job k6-blip-fpm 180
  FPM_SUMMARY=$(extract_summary "$(pod_of_job k6-blip-fpm)")
  [ -n "$FPM_SUMMARY" ] || fail "no k6 summary found in fpm job logs"
}

# --- comparison table --------------------------------------------------
extract_metrics() {
  # k6 puts all counter/rate/trend numbers under .metrics.<name>.values.
  # http_req_failed is a Rate: .values.rate is the failure fraction;
  # .values.passes counts requests marked failed (true) and .values.fails
  # counts successes (false) - k6 quirk. So the count of failed requests
  # is .passes on http_req_failed.
  # Emit: reqs failed_count fail_rate avg p95 p99 max
  local json=$1
  jq -r '
    .metrics as $m
    | (($m.http_reqs.values.count // 0)|tostring) + " "
    + (($m.http_req_failed.values.passes // 0)|tostring) + " "
    + (($m.http_req_failed.values.rate // 0)|tostring) + " "
    + (($m.http_req_duration.values.avg // 0)|tostring) + " "
    + (($m.http_req_duration.values["p(95)"] // 0)|tostring) + " "
    + (($m.http_req_duration.values["p(99)"] // 0)|tostring) + " "
    + (($m.http_req_duration.values.max // 0)|tostring)
  ' <<<"$json"
}

fmt_ms() { awk -v v="$1" 'BEGIN{printf "%.2f ms", v}'; }
fmt_pct() { awk -v v="$1" 'BEGIN{printf "%.2f%%", v*100}'; }

print_table() {
  read -r e_reqs e_fail e_frate e_avg e_p95 e_p99 e_max < <(extract_metrics "$EPHPM_SUMMARY")
  read -r f_reqs f_fail f_frate f_avg f_p95 f_p99 f_max < <(extract_metrics "$FPM_SUMMARY")

  echo
  echo "======================================================"
  echo "  A/B COMPARISON  (constant 50 iters/s x 120s)"
  echo "======================================================"
  printf "%-14s | %-22s | %-22s\n" "Metric" "ePHPm (deploy)" "php-fpm (rolling)"
  printf "%-14s-+-%-22s-+-%-22s\n" "--------------" "----------------------" "----------------------"
  printf "%-14s | %-22s | %-22s\n" "requests"     "$e_reqs"                    "$f_reqs"
  printf "%-14s | %-22s | %-22s\n" "failed"       "$e_fail"                    "$f_fail"
  printf "%-14s | %-22s | %-22s\n" "fail rate"    "$(fmt_pct "$e_frate")"      "$(fmt_pct "$f_frate")"
  printf "%-14s | %-22s | %-22s\n" "avg"          "$(fmt_ms "$e_avg")"         "$(fmt_ms "$f_avg")"
  printf "%-14s | %-22s | %-22s\n" "p95"          "$(fmt_ms "$e_p95")"         "$(fmt_ms "$f_p95")"
  printf "%-14s | %-22s | %-22s\n" "p99"          "$(fmt_ms "$e_p99")"         "$(fmt_ms "$f_p99")"
  printf "%-14s | %-22s | %-22s\n" "max"          "$(fmt_ms "$e_max")"         "$(fmt_ms "$f_max")"
  echo

  # Verdict:
  #   - if ephpm=0 fails AND fpm>0 fails: ephpm wins on availability
  #   - if both=0 fails: k8s readiness gates + fastcgi keepalive saved fpm
  #     from dropping requests; report the p99 gap honestly.
  local verdict
  if [ "$e_fail" = "0" ] && [ "$f_fail" != "0" ]; then
    verdict="ePHPm: zero failed requests during deploy; php-fpm dropped $f_fail requests during rolling restart."
  elif [ "$e_fail" = "0" ] && [ "$f_fail" = "0" ]; then
    verdict="Both stacks kept 100% availability. K8s readiness gates protected the fpm rollout at 50 rps; the recompile blip is visible in the max column of whichever side triggered the cache-bust."
  else
    verdict="Unexpected: ePHPm dropped $e_fail requests during deploy. See raw summaries above."
  fi
  echo "VERDICT: $verdict"
}

apply_stacks
# Preserve the image override the manifest still pins the published tag.
kubectl -n "$NS" set image statefulset/opcache-demo ephpm=ephpm-v040-rc:final >/dev/null
wait_ready
warm_all
run_ephpm
run_fpm
print_table
