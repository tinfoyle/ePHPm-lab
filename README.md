# ePHPm Lab: PHP App Compatibility And Performance Notes

Author: Benjamin Pace

This repository is a reproducible Kubernetes lab for comparing current ePHPm with the standard PHP-FPM/nginx deployment shape.

It is meant to answer a practical operator question:

> If I run a PHP application today, where does ePHPm look promising, and where should I still expect PHP-FPM to be the safer baseline?

For the history of the testing process, including the early false starts and the upstream follow-up, read:

- [docs/ephpm-vs-php-fpm-lab-report.md](docs/ephpm-vs-php-fpm-lab-report.md)
- [docs/follow-up-opcache.md](docs/follow-up-opcache.md)
- [docs/ephpm-0.4.0-retest.md](docs/ephpm-0.4.0-retest.md)
- [docs/current-findings.md](docs/current-findings.md)

## Current Takeaway

ePHPm is most compelling when the application can use runtime features that PHP-FPM does not provide:

- clustered OPcache invalidation without rolling PHP processes
- persistent worker-style deployments
- native services such as ePHPm KV
- lower overhead on adapted worker/native-service workloads

PHP-FPM remains the safest default for arbitrary PHP applications, legacy/plugin-heavy apps, and teams that need maximum operational familiarity today.

## Application Fit Matrix

| Application / workload shape | Tested here? | Current read | Notes |
| --- | --- | --- | --- |
| Clustered PHP app with OPcache deploy invalidation | Yes | Strong ePHPm case | ePHPm invalidated OPcache across two pods with one `ephpm deploy`, no PHP process rollout. |
| Laravel-style persistent worker with hot cache paths | Yes | Strong ePHPm case | Adapted Laravel/KV workload favored ePHPm worker mode plus native KV. |
| Cache-heavy app that can use native ePHPm KV | Yes, indirectly | Strong ePHPm case | Best v4 result came from avoiding Redis/Predis/TCP on hot paths. |
| Plain PHP micro endpoints | Yes | ePHPm 0.4.0 competitive/winning in this lab | Still too tiny to be the main value proposition. |
| Synthetic app-shaped PHP | Yes | ePHPm 0.4.0 wins | Useful signal, but still not a real app. |
| Traditional Laravel in normal request mode | Yes | Mixed | The synthetic Laravel v4 request-mode test was competitive for ePHPm; Krayin request mode still favored PHP-FPM. |
| Real Laravel app adapted to ePHPm worker mode | Yes, v3b | Promising | Krayin worker mode completed the most work and had the lowest average latency in the controlled three-way rerun, with a slightly higher p95 than FPM. |
| WordPress | Not yet | Open | Important future target: plugins, OPcache, object cache, and normal PHP assumptions. |
| Drupal | Not yet | Open | Good CMS-heavy target with meaningful bootstrap/cache behavior. |
| Symfony | Not yet | Open | Especially interesting in worker-style serving. |
| Composer-heavy custom app | Not yet | Open | Needs realistic autoload/dependency graph testing. |
| Need no-surprises production certainty today | Operational judgment | PHP-FPM advantage | PHP-FPM has the longer track record, wider extension expectations, and more operator muscle memory. |

## Current Measured Comparisons

### ePHPm 0.4.0 Retest Progression

The original v1-v4 tests were rerun with the current published ePHPm image:

```text
ephpm/ephpm:v0.4.0-php8.4
```

| Test | Workload | Current result | Practical read |
| --- | --- | --- | --- |
| v1 | Tiny PHP hello and CPU routes | ePHPm won avg latency on both; PHP-FPM had better hello p95 | Useful sanity check, not a real workload. |
| v2 | Synthetic front-controller app | ePHPm won avg and p95 | ePHPm 0.4.0 looks materially better than the early run here. |
| v3 | Krayin CRM in normal request mode | PHP-FPM won | Real apps still need direct validation; request mode is not a universal win. |
| v3b | Krayin CRM: PHP-FPM vs ePHPm request vs ePHPm worker | Worker completed 532 iterations with 69 drops; FPM completed 529; request mode 519 | Worker mode led on completed work and average latency, while FPM had the best p95. |
| v4 | Laravel cache-heavy app at 20 rps | ePHPm worker won; request mode was competitive | Native KV and worker mode are where ePHPm gets interesting. |
| v4 rate-160 | Same Laravel app under pressure | ePHPm worker held 159.27 iterations/s; PHP-FPM completed 100.02/s | Strongest current ePHPm result in this repo. |

Detailed tables are in [docs/ephpm-0.4.0-retest.md](docs/ephpm-0.4.0-retest.md).

### v4 Laravel Worker + Native KV

Architecture:

```text
k6 -> Service -> ePHPm worker -> native KV
k6 -> Service -> nginx -> PHP-FPM -> Predis/TCP -> Redis
```

Rate: `20 iterations/s` for `75s`.

| Runtime | Cache path | HTTP requests | Iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 12.12ms | 9.52ms | 23.55ms | 45.77ms | 0 |
| ePHPm 0.4.0 request mode | Native ePHPm KV | 1512 | 1501 | 11.24ms | 9.48ms | 20.69ms | 34.39ms | 0 |
| ePHPm 0.4.0 worker mode | Native ePHPm KV | 1512 | 1501 | 6.88ms | 4.30ms | 12.15ms | 57.45ms | 0 |

Same workload, quick rate-8 pressure test:

Rate: `160 iterations/s` for `45s`.

| Runtime | Completed iterations | Iteration rate | Dropped iterations | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx + Redis | 4676 | 100.02/s | 2525 | 1.53s | 1.75s | 1.97s | 0 |
| ePHPm 0.4.0 worker mode | 7179 | 159.27/s | 22 | 3.67ms | 168.82ms | 396.46ms | 0 |

This is not a universal runtime victory. It is evidence that ePHPm can become compelling when the app and deployment model use ePHPm's worker/native-service architecture.

### Clustered OPcache Invalidation

Image:

```text
ephpm/ephpm:v0.4.0-php8.4
```

This test compares ePHPm clustered OPcache invalidation against the PHP-FPM equivalent: rolling PHP-FPM pods to clear OPcache when `opcache.validate_timestamps=0`.

Correctness passed:

```text
PASS: one deploy on opcache-demo-0 invalidated OPcache on opcache-demo-0 opcache-demo-1
```

Architecture:

```text
k6 -> Service -> ePHPm cluster -> ephpm deploy -> clustered OPcache invalidation
k6 -> Service -> nginx -> PHP-FPM -> rolling restart to clear OPcache
```

Rate: `50 iterations/s` for `120s`.

| Metric | ePHPm deploy | PHP-FPM rolling |
| --- | ---: | ---: |
| requests | 6001 | 6001 |
| failed | 0 | 0 |
| fail rate | 0.00% | 0.00% |
| avg | 1.06 ms | 2.19 ms |
| p95 | 2.47 ms | 5.57 ms |
| p99 | 5.98 ms | 13.63 ms |
| max | 21.75 ms | 40.50 ms |

Both stacks stayed available. The ePHPm advantage here is operational shape and latency: one deploy signal invalidated cache across the ePHPm cluster without rolling PHP processes.

## What To Test Next

The goal is for this repo to become a practical lookup table for real PHP applications.

| Future test | Why it matters |
| --- | --- |
| WordPress | The obvious CMS test: plugins, OPcache behavior, object cache, admin paths, and normal PHP assumptions. |
| Drupal | Heavier CMS behavior with substantial bootstrap and cache layers. |
| Symfony demo/API app | Good framework comparison, especially with a worker-style model. |
| Laravel Octane / Swoole / RoadRunner / ePHPm | ePHPm should be compared against other persistent-worker PHP runtimes, not only PHP-FPM. |
| PHP-FPM with `phpredis` instead of Predis | Strengthens the PHP-FPM cache baseline. |
| Krayin three-way rerun | Compare PHP-FPM, ePHPm request mode, and ePHPm worker mode sequentially under the same cluster conditions. |
| Larger nodes | The original LKE nodes were small; bigger nodes would show whether the shape holds with more CPU and memory headroom. |
| Metrics API installed for CPU/memory | Latency without CPU/memory data is incomplete. |
| Sustained 10-30 minute runs | Persistent workers need soak testing for leaks, drift, and tail behavior. |
| Multiple worker counts | Worker count and concurrency tuning may change the throughput knee and p95/p99 behavior. |
| Failure/restart behavior | Production confidence depends on deploys, crashes, stale state, and pod restarts. |

## Repository Layout

| Path | Purpose |
| --- | --- |
| `docs/` | Historical narrative, follow-up, and raw findings. |
| `k8s/` | Kubernetes manifests and k6 jobs for each benchmark phase. |
| `patches/` | Local patch used during the older source-built worker-mode phase. |
| `scripts/` | Helper scripts retained from earlier source-build experiments and v4 worker runs. |
| `apps/` | Ignored local upstream checkouts created by `scripts/clone-inputs.sh`. Not committed. |

## Important Caveats

This is a reproducible lab, not a universal benchmark.

- The original cluster was a three-node Linode LKE cluster using `g6-standard-1` nodes.
- Kubernetes Metrics API was not installed, so CPU and memory correlation is incomplete.
- Some historical docs mention original LKE node names and temporary image tags. The committed manifests have been made portable where practical.
- The current retest uses the published `ephpm/ephpm:v0.4.0-php8.4` image. Older narrative docs preserve the source-built worker-mode phase because that was part of the testing history.
- The manifests are intentionally small and self-contained. They generate apps in init containers rather than assuming a long-lived application image.

## Prerequisites

You need:

- A Kubernetes cluster with enough room for the test pods.
- `kubectl` configured for that cluster.
- Docker or another compatible container builder.
- Access to a registry your cluster can pull from.
- Bash, Git, and standard Unix tools.

The original work was done from WSL, but WSL is not required.

## Reproduce The Current OPcache Test

Deploy both OPcache stacks:

```bash
kubectl apply -f k8s/opcache-cluster.yaml
kubectl apply -f k8s/opcache-fpm-cluster.yaml
```

Run the correctness test:

```bash
bash k8s/opcache-cluster-test.sh
```

Run the A/B blip test:

```bash
bash k8s/opcache-blip-test.sh
```

For a local kind cluster with a locally loaded ePHPm image, override the image:

```bash
EPHPM_IMAGE=ephpm-v040-rc:final bash k8s/opcache-blip-test.sh
```

For a remote cluster such as LKE, leave `EPHPM_IMAGE` unset so the published image in the manifest is used.

## Reproduce The Laravel v4 Tests

The Laravel v4 tests use the published ePHPm 0.4.0 image in `k8s/laravel-v4.yaml`.

Deploy the app stacks:

```bash
kubectl apply -f k8s/laravel-v4.yaml
kubectl rollout status deployment/laravel-v4-php-fpm -n laravel-v4 --timeout=600s
kubectl rollout status deployment/laravel-v4-ephpm-worker -n laravel-v4 --timeout=600s
kubectl scale deployment/laravel-v4-ephpm -n laravel-v4 --replicas=1
kubectl rollout status deployment/laravel-v4-ephpm -n laravel-v4 --timeout=600s
```

Run the baseline jobs sequentially:

```bash
kubectl delete job k6-v4-php-fpm k6-v4-ephpm k6-v4-ephpm-worker -n laravel-v4 --ignore-not-found
kubectl apply -f k8s/k6-v4-php-fpm.yaml
kubectl wait --for=condition=complete job/k6-v4-php-fpm -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-php-fpm -n laravel-v4

kubectl apply -f k8s/k6-v4-ephpm.yaml
kubectl wait --for=condition=complete job/k6-v4-ephpm -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-ephpm -n laravel-v4

kubectl apply -f k8s/k6-v4-ephpm-worker.yaml
kubectl wait --for=condition=complete job/k6-v4-ephpm-worker -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-ephpm-worker -n laravel-v4
```

Run the rate-8 pressure test sequentially:

Apply the shared rate-8 script:

```bash
kubectl apply -f k8s/k6-v4-rate8.yaml
```

Run ePHPm first:

```bash
kubectl delete job k6-v4-rate8-ephpm-worker -n laravel-v4 --ignore-not-found
kubectl apply -f k8s/k6-v4-rate8-ephpm-worker.yaml
kubectl wait --for=condition=complete job/k6-v4-rate8-ephpm-worker -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-rate8-ephpm-worker -n laravel-v4
```

Then run PHP-FPM:

```bash
kubectl delete job k6-v4-rate8-php-fpm -n laravel-v4 --ignore-not-found
kubectl apply -f k8s/k6-v4-rate8-php-fpm.yaml
kubectl wait --for=condition=complete job/k6-v4-rate8-php-fpm -n laravel-v4 --timeout=300s
kubectl logs job/k6-v4-rate8-php-fpm -n laravel-v4
```

Do not run the two rate-8 jobs concurrently if you want a fair side-by-side comparison.

## Reproduce The Krayin v3b Worker Test

Deploy Krayin and keep only MySQL plus the worker target running on small clusters:

```bash
kubectl apply -f k8s/krayin-v3.yaml
kubectl scale deployment/krayin-php-fpm deployment/krayin-ephpm -n krayin-bench --replicas=0
kubectl rollout status deployment/krayin-mysql -n krayin-bench --timeout=300s
kubectl rollout status deployment/krayin-ephpm-worker -n krayin-bench --timeout=900s
```

If MySQL was recreated, rerun the install job:

```bash
kubectl delete job krayin-install -n krayin-bench --ignore-not-found
kubectl apply -f k8s/krayin-v3.yaml
kubectl wait --for=condition=complete job/krayin-install -n krayin-bench --timeout=900s
```

Run the worker benchmark:

```bash
kubectl delete job k6-v3b-ephpm-worker -n krayin-bench --ignore-not-found
kubectl apply -f k8s/k6-v3b-ephpm-worker.yaml
kubectl wait --for=condition=complete job/k6-v3b-ephpm-worker -n krayin-bench --timeout=300s
kubectl logs job/k6-v3b-ephpm-worker -n krayin-bench
```

## Historical Tests

The full earlier raw runs are intentionally kept in the narrative docs rather than repeated here:

- [docs/ephpm-vs-php-fpm-lab-report.md](docs/ephpm-vs-php-fpm-lab-report.md)
- [docs/current-findings.md](docs/current-findings.md)

## Cleanup

Most resources live in these namespaces:

```bash
kubectl delete namespace opcache-demo --ignore-not-found
kubectl delete namespace php-bench --ignore-not-found
kubectl delete namespace laravel-v4 --ignore-not-found
```

The Krayin test also uses the namespace declared in `k8s/krayin-v3.yaml`.

## Public Repo Safety Notes

This repo intentionally does not include:

- kubeconfig files
- Kubernetes tokens
- upstream Git checkouts under `apps/`
- built container images
- local `.env` files

The benchmark-only Krayin credentials (`admin@example.com` / `admin123`) are included in manifests because they are generated inside the throwaway test namespace.

## License

This lab repository is licensed under the MIT License, matching ePHPm.
