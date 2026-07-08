# ePHPm vs PHP-FPM Kubernetes Lab

Author: Benjamin Pace

This repository contains the manifests, helper scripts, patches, and writeups from a small Kubernetes benchmark lab comparing ePHPm against the official Docker Hub PHP-FPM image.

The short version:

- ePHPm did **not** outperform PHP-FPM in normal request mode in these tests.
- ePHPm became compelling only after switching to a source-built ePHPm worker runtime plus native ePHPm KV.
- The most useful finding is not just the winning number. It is the deployment shape required to reach that number.

For the narrative report, start here:

- [docs/ephpm-vs-php-fpm-lab-report.md](docs/ephpm-vs-php-fpm-lab-report.md)
- [docs/current-findings.md](docs/current-findings.md)

## Repository Layout

| Path | Purpose |
| --- | --- |
| `docs/` | Narrative report and raw findings from the lab. |
| `k8s/` | Kubernetes manifests and k6 jobs for each benchmark phase. |
| `patches/` | Local patch needed to build the ePHPm source image used for worker-mode tests. |
| `scripts/` | Helper scripts for cloning inputs, building ePHPm, rendering manifests, and running v4 worker tests. |
| `apps/` | Ignored local upstream checkouts created by `scripts/clone-inputs.sh`. Not committed. |

## What Was Tested

| Phase | Workload | ePHPm mode | Result |
| --- | --- | --- | --- |
| v1 | Tiny PHP scripts | Public image, normal mode | PHP-FPM slightly ahead |
| v2 | App-shaped synthetic PHP | Public image, normal mode | PHP-FPM ahead |
| v3 | Krayin CRM | Public image, normal mode | PHP-FPM strongly ahead |
| v4 normal | Laravel + cache | Public image, normal mode + native KV | PHP-FPM strongly ahead |
| v4 worker attempt | Laravel + cache | Public image, worker config | Blocked by runtime/package mismatch |
| v4 source worker | Laravel + cache | Source-built worker mode + native KV | ePHPm clear win |
| v4 rate-8 | Laravel + cache | Source-built worker mode + native KV | ePHPm sustained far more scheduled work |

## Headline Results

### v4 Worker Baseline

Rate: `20 iterations/s` for `75s`.

| Runtime | Cache path | HTTP requests | Iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | Native ePHPm KV SAPI | 1512 | 1501 | 4.71ms | 3.90ms | 10.16ms | 16.66ms | 0 |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 11.33ms | 9.02ms | 19.75ms | 44.13ms | 0 |

### v4 Rate-8 Quick Test

Rate: `160 iterations/s` for `45s`.

| Runtime | Completed iterations | Iteration rate | Dropped iterations | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 7091 | 156.53/s | 110 | 3.83ms | 819.08ms | 1.23s | 0 |
| PHP-FPM + nginx + Redis | 4744 | 101.79/s | 2457 | 1.49s | 1.72s | 2.50s | 0 |

## Important Caveats

This is a reproducible lab, not a universal benchmark.

- The original cluster was a three-node Linode LKE cluster using `g6-standard-1` nodes.
- Kubernetes Metrics API was not installed, so CPU and memory correlation is incomplete.
- Historical docs mention the original LKE node names and a temporary `ttl.sh` image. The committed manifests have been made portable by removing `nodeName` pins and replacing the expired worker image with a placeholder.
- The v4 worker result depends on a source-built ePHPm image. The public `ephpm/ephpm:8.4` image did not provide the worker runtime path that produced the win in this lab.
- The manifests are intentionally small and self-contained. They generate apps in init containers rather than assuming a long-lived application image.

## Prerequisites

You need:

- A Kubernetes cluster with enough room for the test pods.
- `kubectl` configured for that cluster.
- Docker or another compatible container builder.
- Access to a registry your cluster can pull from.
- Bash, Git, and standard Unix tools.

The original work was done from WSL, but WSL is not required.

## Reproduce The v4 Worker Tests

The v4 worker tests are the most important reproduction path because they are where ePHPm finally showed its advantage.

### 1. Clone Upstream Inputs

```bash
scripts/clone-inputs.sh
```

This creates ignored local checkouts:

| Checkout | Commit |
| --- | --- |
| `apps/ephpm` | `469c51ec749678d73984fea8f788b6727eb29f30` |
| `apps/laravel-crm` | `7d426f901b18f043eb91e425c7bdd3e9cba568ab` |

The script applies [patches/ephpm-source-build.patch](patches/ephpm-source-build.patch) to the ePHPm checkout.

### 2. Build ePHPm From Source

```bash
IMAGE=ghcr.io/YOUR_ORG/ephpm:source-469c51e \
  scripts/build-ephpm-source-image.sh
```

Push the image to a registry your cluster can pull:

```bash
docker push ghcr.io/YOUR_ORG/ephpm:source-469c51e
```

### 3. Render The v4 Manifest

The committed manifest contains `REPLACE_WITH_YOUR_EPHPM_SOURCE_IMAGE` so the repo does not point at an expired temporary image.

```bash
EPHPM_SOURCE_IMAGE=ghcr.io/YOUR_ORG/ephpm:source-469c51e \
  scripts/render-laravel-v4.sh
```

This writes:

```text
.generated/k8s/laravel-v4.yaml
```

### 4. Deploy And Run The Baseline Worker Comparison

```bash
scripts/run-v4-worker-baseline.sh
```

That script:

1. Applies the rendered Laravel v4 manifest.
2. Waits for PHP-FPM and ePHPm worker deployments.
3. Runs the PHP-FPM k6 job.
4. Runs the ePHPm worker k6 job.
5. Prints both k6 summaries.

### 5. Run The Rate-8 Test Sequentially

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

## Earlier Phases

The earlier phases are included because they explain the path we took and the false starts we hit.

| Phase | Deploy | Run |
| --- | --- | --- |
| v1 tiny scripts | `kubectl apply -f k8s/php-benchmark.yaml` | `k8s/k6-*.yaml`, `k8s/inspect-*.yaml` |
| v2 synthetic app | `kubectl apply -f k8s/php-benchmark-v2.yaml` | `k8s/k6-v2-*.yaml` |
| v3 Krayin CRM | `kubectl apply -f k8s/krayin-v3.yaml` | `k8s/k6-v3-*.yaml` |
| v4 normal mode | `kubectl apply -f .generated/k8s/laravel-v4.yaml` | `k8s/k6-v4-php-fpm.yaml`, `k8s/k6-v4-ephpm.yaml` |

Some earlier manifests generate application code dynamically and may take several minutes on small nodes.

## Cleanup

Most resources live in these namespaces:

```bash
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
