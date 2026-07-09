# Five-Way PHP Runtime Comparison

This benchmark compares five PHP runtimes under identical resource constraints
(0.25 CPU / 320 Mi memory per pod) on a kind cluster with fixtures served from
ConfigMaps. It addresses the "Octane/Swoole/RoadRunner/ePHPm comparison" item
from the ePHPm-lab report's next-tests list.

## Runtimes

| Runtime | Image | PHP |
|---------|-------|-----|
| ePHPm v0.4.0 | `ephpm/ephpm:v0.4.0-php8.4` | 8.4 ZTS |
| nginx + php-fpm | `nginx:1.27-alpine` + `php:8.4-fpm-alpine` | 8.4 |
| FrankenPHP | `dunglas/frankenphp:latest` | 8.5 (image default; see caveat) |
| Swoole | `phpswoole/swoole:php8.4` | 8.4 |
| RoadRunner | `php:8.4-cli-alpine` + `ghcr.io/roadrunner-server/roadrunner:2024` | 8.4 |

## Class A vs Class B

These runtimes fall into two categories that must NOT be compared in the same table.

**Class A — Drop-in runtimes.** Serve `.php` files from a docroot on each
request, just like Apache or nginx. No application changes needed.

- ePHPm
- nginx + php-fpm (opcache + JIT enabled)
- FrankenPHP (classic mode, not worker mode)

Benchmark paths: `/hello.php`, `/cpu.php`

**Class B — Worker/persistent-process runtimes.** Require custom server or
worker bootstrap code. The application runs in a long-lived process and handles
requests via an event loop or message-passing protocol. Not drop-in replacements.

- Swoole (`Swoole\Http\Server`, ~20 lines of bootstrap)
- RoadRunner (PSR-7 worker loop via spiral/roadrunner-http, ~35 lines)

Benchmark paths: `/hello`, `/cpu`

## Fixtures

- **hello**: tiny JSON echo (`{"ok":true,"t":<microtime>}`)
- **cpu**: 5000-round sha256 chain (`{"h":"<hex16>"}`)

## Local Reference Numbers

Measured on one developer machine with podman, 0.25 CPU / 320 Mi per container,
`hey` keep-alive, best of 2 x 30 s runs. These numbers exist so you can sanity-
check your cluster results; they are not claims about production throughput.

### Class A

| Runtime | hello c=1 avg | hello c=16 avg | hello c=16 RPS | cpu c=16 RPS |
|---------|:---:|:---:|:---:|:---:|
| ePHPm v0.4.0 php8.4 (ZTS) | 1.4 ms | 4.2 ms | 3807 | 82 |
| nginx + php-fpm 8.4 (opcache+JIT) | 1.4 ms | 17.3 ms | 925 | 79 |
| FrankenPHP classic (php 8.5 ZTS) | 6.1 ms | 59.4 ms | 269 | 125 |

### Class B

| Runtime | hello c=1 avg | hello c=16 avg | hello c=16 RPS | cpu c=16 RPS |
|---------|:---:|:---:|:---:|:---:|
| Swoole php8.4 (1 worker) | 0.4 ms | 2.4 ms | 6539 | 206 |
| RoadRunner php8.4 (1 worker) | 2.1 ms | 29.1 ms | 549 | 68 |

## Caveats

- **FrankenPHP ships PHP 8.5**, not 8.4. The `dunglas/frankenphp:latest` image
  bundles PHP 8.5 (ZTS). All other runtimes use PHP 8.4. This is a minor
  version difference; treat FrankenPHP numbers as indicative only when comparing
  across classes.

- **RoadRunner with 1 worker at 0.25 CPU is its worst case.** RoadRunner uses
  IPC between the Go server and PHP workers; at 1 worker the IPC round-trip
  dominates. Production RoadRunner typically runs `num_workers = nproc`. The
  reference numbers reflect that IPC overhead, not RR's ceiling.

- **Swoole and RoadRunner are not drop-in.** They require a custom server
  bootstrap (Swoole, ~20 LoC) or PSR-7 worker loop (RoadRunner, ~35 LoC).
  They are Class B runtimes and should only be compared with each other.

- **Load generator ran in a sibling container** on the same node. Network path
  is loopback-equivalent inside the kind node. Absolute numbers will differ
  on real hardware.

- **Reference numbers are from our hardware.** The manifests exist so you can
  reproduce on your own cluster and get numbers relevant to your environment.

## Reproducing

```bash
# 1. Build the RoadRunner image (requires Docker/podman, kind CLI, internet access):
./rr/build-rr.sh --cluster-name ephpm-lab   # adjust cluster name if needed

# 2. Apply the full stack and run all k6 jobs sequentially:
./scripts/run-runtimes-bench.sh

# Or step through manually:
kubectl apply -f k8s/runtimes-bench.yaml
# Delete the auto-fired k6 Jobs (the manifest creates them on apply):
kubectl delete job k6-bench-ephpm k6-bench-nginx-fpm k6-bench-frankenphp \
  k6-bench-swoole k6-bench-rr -n runtimes-bench --ignore-not-found
# Wait for all deployments:
for d in bench-ephpm bench-nginx-fpm bench-frankenphp bench-swoole bench-rr; do
  kubectl rollout status deployment/$d -n runtimes-bench --timeout=300s
done
# Then reapply to recreate jobs, or use the driver script.
kubectl wait --for=condition=complete job/k6-bench-ephpm -n runtimes-bench --timeout=300s
kubectl logs job/k6-bench-ephpm -n runtimes-bench

# Tear down:
kubectl delete namespace runtimes-bench
```

### RoadRunner image

The `bench-rr:local` image must be built locally because kind cluster nodes
have no access to `apk` package mirrors at pod start. The `rr/` directory
contains everything needed:

```
rr/Dockerfile      Multi-stage build: composer vendor + rr binary + php:8.4-cli-alpine
rr/composer.json   spiral/roadrunner ^2024 + spiral/roadrunner-http ^3.5 + nyholm/psr7
rr/worker.php      PSR-7 worker loop (~35 LoC)
rr/.rr.yaml        RoadRunner config (1 worker, port 8080)
rr/build-rr.sh     Build + kind load helper script
```

The Deployment uses `imagePullPolicy: Never` so kind reads the locally-loaded
image without contacting a registry.

## Manifest Layout

```
k8s/runtimes-bench.yaml    Single self-contained manifest:
                             - Namespace
                             - ConfigMaps (fixtures, configs, k6 script)
                             - 5 Deployments + 5 Services
                             - 5 k6 Jobs
scripts/run-runtimes-bench.sh  Driver: apply, wait, run jobs, print summaries
```
