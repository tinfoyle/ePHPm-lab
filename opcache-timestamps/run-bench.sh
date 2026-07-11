#!/usr/bin/env bash
# opcache.validate_timestamps cost bench — driver.
#
# Measures the same image and fixture under three OPcache configurations:
#   A  validate_timestamps=1, revalidate_freq=2   (current image default)
#   B  validate_timestamps=1, revalidate_freq=60  (the middle setting)
#   C  validate_timestamps=0                      (proposed serve default)
#
# For each variant x docroot it runs a warmup, then $BENCH_RUNS x
# $BENCH_DURATION hey runs (keep-alive, c=$BENCH_CONCURRENCY), keeps the best
# run, and asserts a 100% [200] status distribution. On the overlay docroot it
# then runs the staleness lane: mutate one class file and assert
#   A picks the change up within ~2 s,
#   B does NOT within 30 s (and does by ~60 s),
#   C never does — until `ephpm cache reset`, which must apply immediately.
#
# One server container at a time; nothing else should be running on the host
# for clean numbers. Requires: podman, hey, curl, jq.
#
# Usage:
#   bash run-bench.sh                                  # full matrix
#   EPHPM_IMAGE=ephpm/ephpm:v0.4.1 bash run-bench.sh   # re-run on a new tag
#   BENCH_DOCROOTS=overlay BENCH_SKIP_STALENESS=1 bash run-bench.sh  # quick
set -euo pipefail

IMAGE="${EPHPM_IMAGE:-docker.io/ephpm/ephpm:latest}"
PORT="${BENCH_PORT:-18080}"
DURATION="${BENCH_DURATION:-30s}"
WARMUP="${BENCH_WARMUP:-5s}"
CONCURRENCY="${BENCH_CONCURRENCY:-16}"
NFILES="${BENCH_NFILES:-500}"
CPUS="${BENCH_CPUS:-1}"
MEMORY="${BENCH_MEMORY:-512m}"
RUNS="${BENCH_RUNS:-2}"                      # best-of, as in RUNTIMES-BENCH.md
DOCROOTS="${BENCH_DOCROOTS:-overlay volume}" # overlay = container fs, volume = podman named volume
SKIP_STALENESS="${BENCH_SKIP_STALENESS:-}"

CTR=opcache-ts-bench
VOL=opcache-ts-web
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="http://127.0.0.1:${PORT}/index.php"
STATUS_URL="http://127.0.0.1:${PORT}/status.php"
VARIANTS=(a-vt1-freq2 b-vt1-freq60 c-vt0)

# Windows git-bash: podman is a remote client, so host paths must be
# C:/-style, and MSYS argument mangling must be off for container-side
# paths like ephpm-ctr:/bench.
case "$(uname -s)" in
    MINGW* | MSYS*)
        DIR="$(cygpath -m "$DIR")"
        export MSYS_NO_PATHCONV=1
        ;;
esac

SUMMARY=()

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup() {
    podman rm -f "$CTR" >/dev/null 2>&1 || true
    podman volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── server lifecycle ─────────────────────────────────────────────────────────

start_server() { # $1 variant, $2 docroot mode (overlay|volume)
    local variant="$1" docroot="$2" vol_args=() i=0
    podman rm -f "$CTR" >/dev/null 2>&1 || true
    if [ "$docroot" = volume ]; then
        podman volume rm -f "$VOL" >/dev/null 2>&1 || true
        podman volume create "$VOL" >/dev/null
        vol_args=(-v "$VOL:/web")
    fi
    # `sh /bench/start.sh` replaces the image CMD; the tini entrypoint stays.
    podman create --name "$CTR" \
        --cpus "$CPUS" --memory "$MEMORY" \
        -p "${PORT}:8080" \
        -e "VARIANT=$variant" -e "NFILES=$NFILES" \
        ${vol_args[@]+"${vol_args[@]}"} \
        "$IMAGE" sh /bench/start.sh >/dev/null
    # No bind mounts (see container/start.sh header): copy the pieces in.
    podman cp "$DIR/container" "$CTR:/bench"
    podman cp "$DIR/configs" "$CTR:/bench/configs"
    podman start "$CTR" >/dev/null

    until curl -fsS -o /dev/null "$STATUS_URL" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 120 ]; then
            podman logs "$CTR" 2>&1 | tail -20 >&2
            fail "server not ready after 60s ($variant/$docroot)"
        fi
        sleep 0.5
    done
}

assert_ini() { # $1 variant — verify the ini knobs actually took effect
    local variant="$1" status vt freq
    status=$(curl -fsS "$STATUS_URL")
    if [ "$(jq -r .opcache_enabled <<<"$status")" != true ]; then
        fail "OPcache not enabled ($variant): $status"
    fi
    vt=$(jq -r .validate_timestamps <<<"$status")
    freq=$(jq -r .revalidate_freq <<<"$status")
    case "$variant" in
        a-vt1-freq2) [ "$vt" = 1 ] && [ "$freq" = 2 ] || fail "ini mismatch ($variant): $status" ;;
        b-vt1-freq60) [ "$vt" = 1 ] && [ "$freq" = 60 ] || fail "ini mismatch ($variant): $status" ;;
        c-vt0) [ "$vt" = 0 ] || [ -z "$vt" ] || fail "ini mismatch ($variant): $status" ;;
    esac
}

# ── throughput lane ──────────────────────────────────────────────────────────

HEY_OUT=""

hey_run() { # one measured run into $HEY_OUT; retries transport-error runs
    local attempt tmp
    tmp=$(mktemp)
    for attempt in 1 2 3; do
        hey -z "$DURATION" -c "$CONCURRENCY" "$URL" >"$tmp"
        # A dropped keep-alive connection (occasional on podman-machine port
        # forwards) makes the whole run suspect — rerun it, don't average it.
        # (awk, not grep: some Windows git-bash setups ship a broken grep.)
        if awk '/^Error distribution/ { found = 1 } END { exit found ? 0 : 1 }' "$tmp"; then
            echo "    transport errors in attempt $attempt, re-running..."
            continue
        fi
        HEY_OUT=$(cat "$tmp")
        rm -f "$tmp"
        return 0
    done
    cat "$tmp" >&2
    rm -f "$tmp"
    fail "hey reported transport errors in 3 consecutive attempts"
}

assert_all_200() { # exactly one status-code line and it must be [200] —
    # a single 429/5xx taints the run (the rate-limiter lesson from
    # RUNTIMES-BENCH.md).
    local codes
    codes=$(awk '/^Status code distribution/ { s = 1; next }
                 s && $1 ~ /^\[/ { n++; last = $1 }
                 END { print n + 0, last }' <<<"$HEY_OUT")
    if [ "$codes" != "1 [200]" ]; then
        echo "$HEY_OUT" >&2
        fail "non-200 responses in run (status lines: $codes)"
    fi
}

bench_variant() { # $1 variant, $2 docroot
    local variant="$1" docroot="$2" best="" best_rps=0 r rps p50 p99
    echo "==> [$variant/$docroot] warmup ($WARMUP)"
    hey -z "$WARMUP" -c "$CONCURRENCY" "$URL" >/dev/null
    for r in $(seq 1 "$RUNS"); do
        echo "==> [$variant/$docroot] run $r/$RUNS ($DURATION, c=$CONCURRENCY)"
        hey_run
        assert_all_200
        rps=$(awk '/Requests\/sec:/ {print $2}' <<<"$HEY_OUT")
        p50=$(awk '$1 == "50%" {printf "%.1f", $3 * 1000}' <<<"$HEY_OUT")
        p99=$(awk '$1 == "99%" {printf "%.1f", $3 * 1000}' <<<"$HEY_OUT")
        echo "    rps=$rps p50=${p50}ms p99=${p99}ms (100% 200s)"
        if awk -v a="$rps" -v b="$best_rps" 'BEGIN { exit !(a > b) }'; then
            best_rps=$rps
            best="$rps $p50 $p99"
        fi
    done
    SUMMARY+=("$variant|$docroot|$best")
}

# ── staleness lane ───────────────────────────────────────────────────────────

rev() { curl -fsS "$URL" | jq -r .rev; }

wait_rev2() { # $1 timeout_s; prints elapsed seconds, rc=1 on timeout
    local t0 now
    t0=$(date +%s)
    while :; do
        now=$(date +%s)
        if [ $((now - t0)) -gt "$1" ]; then
            return 1
        fi
        if [ "$(rev)" = 2 ]; then
            echo $((now - t0))
            return 0
        fi
        sleep 0.5
    done
}

staleness_variant() { # $1 variant (server already running and warmed)
    local variant="$1" elapsed extra
    echo "==> [$variant] staleness: mutating C0001.php (REV 1 -> 2)"
    [ "$(rev)" = 1 ] || fail "staleness baseline: expected rev=1"
    podman exec "$CTR" sed -i 's/const REV = 1;/const REV = 2;/' /web/lib/C0001.php
    case "$variant" in
        a-vt1-freq2)
            elapsed=$(wait_rev2 15) || fail "A: change not visible within 15s (expected ~2s)"
            [ "$elapsed" -le 5 ] || fail "A: change took ${elapsed}s (expected ~2s + slack)"
            echo "    PASS: A picked up the change in ${elapsed}s (revalidate_freq=2)"
            ;;
        b-vt1-freq60)
            sleep 5
            [ "$(rev)" = 1 ] || fail "B: change visible after 5s (freq=60 not in effect)"
            sleep 25
            [ "$(rev)" = 1 ] || fail "B: change visible after 30s (freq=60 not in effect)"
            echo "    still stale at +30s (correct for freq=60); waiting out the 60s window..."
            extra=$(wait_rev2 90) || fail "B: change not visible within 120s"
            elapsed=$((30 + extra))
            echo "    PASS: B stayed stale >=30s and picked up the change in ~${elapsed}s (revalidate_freq=60)"
            ;;
        c-vt0)
            sleep 5
            [ "$(rev)" = 1 ] || fail "C: change visible after 5s (vt=0 not in effect)"
            sleep 25
            [ "$(rev)" = 1 ] || fail "C: change visible after 30s (vt=0 not in effect)"
            echo "    still stale at +30s (correct for vt=0); running 'ephpm cache reset --all'..."
            podman exec "$CTR" ephpm cache reset --all
            elapsed=$(wait_rev2 10) || fail "C: change not visible within 10s of cache reset"
            echo "    PASS: C stayed stale until explicit reset, then flipped in ${elapsed}s"
            ;;
    esac
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "image=$IMAGE fixture=${NFILES}+1 files cpus=$CPUS mem=$MEMORY hey c=$CONCURRENCY z=$DURATION best-of-$RUNS docroots=[$DOCROOTS]"

for docroot in $DOCROOTS; do
    for variant in "${VARIANTS[@]}"; do
        start_server "$variant" "$docroot"
        assert_ini "$variant"
        bench_variant "$variant" "$docroot"
        if [ "$docroot" = overlay ] && [ -z "$SKIP_STALENESS" ]; then
            staleness_variant "$variant"
        fi
        podman rm -f "$CTR" >/dev/null
    done
done

echo
echo "== RESULTS (best of $RUNS x $DURATION, c=$CONCURRENCY, ${NFILES}-file require chain, 100% 200s) =="
printf '%-14s %-8s %10s %10s %10s\n' variant docroot req/s p50_ms p99_ms
for row in "${SUMMARY[@]}"; do
    variant=${row%%|*}
    rest=${row#*|}
    docroot=${rest%%|*}
    read -r rps p50 p99 <<<"${rest#*|}"
    printf '%-14s %-8s %10s %10s %10s\n' "$variant" "$docroot" "$rps" "$p50" "$p99"
done
