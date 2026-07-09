# ePHPm Lab: Current Kubernetes Comparison

Author: Benjamin Pace

This repository is a reproducible Kubernetes lab for evaluating ePHPm against the standard PHP-FPM/nginx deployment shape.

The README is written from the perspective of someone taking current ePHPm off the shelf today. The full historical story is preserved in `docs/`, including the early tests that failed to show an ePHPm advantage and the follow-up work that made the current results more interesting.

## Current Takeaway

Current ePHPm is most interesting when you use the runtime features that make it different from PHP-FPM:

- clustered OPcache invalidation
- persistent worker-style deployments
- native services such as ePHPm KV
- avoiding process restarts for runtime cache-bust operations

It should not be evaluated only as "PHP-FPM, but with a different binary." The promising results in this repo come from deployment shapes where ePHPm is allowed to behave like an application runtime, not just a request runner.

PHP-FPM still has the edge when the requirement is maximum boring certainty for arbitrary PHP apps. ePHPm starts to look compelling when the app and operator model can use its worker/native-service architecture.

## Should I Use ePHPm?

| Situation | Practical answer today | Why |
| --- | --- | --- |
| Arbitrary legacy PHP app | Probably start with PHP-FPM | PHP-FPM is the safer baseline for unknown code, plugin ecosystems, and standard per-request assumptions. |
| Current ePHPm with clustered OPcache | Worth testing | The v0.4 OPcache test invalidated cache across both ePHPm pods without rolling PHP processes. |
| Laravel/Octane-style persistent worker | Worth testing | Our adapted Laravel/KV worker workload showed a clear ePHPm advantage. |
| Cache-heavy app that can use native ePHPm KV | Strong ePHPm case | The strongest v4 result came from persistent worker mode plus native KV instead of Redis/Predis/TCP. |
| Need no-surprises production operations today | PHP-FPM still wins | PHP-FPM has the longer production track record, wider extension expectations, and more operator muscle memory. |
| Comparing normal request mode only | Retest with current ePHPm before concluding | Earlier normal-mode tests favored PHP-FPM, but they predated the OPcache follow-up and should be treated as historical evidence, not the final word. |

## Current Headline Results

### OPcache Cluster Invalidation

This is the most current off-the-shelf ePHPm result in the repo. It uses the published image:

```text
ephpm/ephpm:v0.4.0-php8.4
```

The test compares ePHPm clustered OPcache invalidation against the PHP-FPM equivalent: rolling the PHP-FPM pods to clear OPcache when `opcache.validate_timestamps=0`.

Correctness passed:

```text
PASS: one deploy on opcache-demo-0 invalidated OPcache on opcache-demo-0 opcache-demo-1
```

The A/B blip test compared:

```text
k6 -> Service -> ePHPm cluster -> ephpm deploy -> clustered OPcache invalidation
```

against:

```text
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

This does not erase the earlier findings. It shows the project responding to a real operator-facing gap and adding a more compelling clustered runtime story.

### Adapted Laravel Worker/KV Shape

Rate: `20 iterations/s` for `75s`.

| Runtime | Cache path | HTTP requests | Iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | Native ePHPm KV SAPI | 1512 | 1501 | 4.71ms | 3.90ms | 10.16ms | 16.66ms | 0 |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 11.33ms | 9.02ms | 19.75ms | 44.13ms | 0 |

Same workload, quick rate-8 pressure test:

Rate: `160 iterations/s` for `45s`.

| Runtime | Completed iterations | Iteration rate | Dropped iterations | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 7091 | 156.53/s | 110 | 3.83ms | 819.08ms | 1.23s | 0 |
| PHP-FPM + nginx + Redis | 4744 | 101.79/s | 2457 | 1.49s | 1.72s | 2.50s | 0 |

**Important caveat:** This is not "ePHPm universally beats PHP-FPM." This is "ePHPm can beat PHP-FPM when the app and deployment model are adapted to ePHPm's worker/native-service architecture."

The important finding is not a universal runtime victory. The important finding is the deployment shape where ePHPm becomes compelling.

## Architecture Shapes That Matter

The current OPcache cluster test:

```text
k6 -> Service -> ePHPm cluster -> ephpm deploy -> clustered OPcache invalidation
```

The adapted Laravel/KV ePHPm shape:

```text
k6 -> Service -> ePHPm worker -> native KV
```

The comparable PHP-FPM shapes:

```text
k6 -> Service -> nginx -> PHP-FPM -> Predis/TCP -> Redis
k6 -> Service -> nginx -> PHP-FPM -> rolling restart to clear OPcache
```

That distinction matters. The best ePHPm results did not come from pointing an arbitrary PHP app at ePHPm and hoping. They came from using the runtime features PHP-FPM does not have.

## Historical Narrative

The older tests are still valuable, but they are no longer the best front-page summary of current ePHPm.

The repo history is:

| Phase | Workload | What it showed |
| --- | --- | --- |
| Early tiny/synthetic tests | Small scripts and app-shaped PHP | PHP-FPM was already extremely strong for simple per-request PHP. |
| Krayin and early Laravel tests | Real/real-ish Laravel workloads | ePHPm normal mode looked poor before the later OPcache work. |
| Worker/native KV tests | Adapted Laravel/KV workload | ePHPm became compelling when using worker mode and native KV. |
| OPcache follow-up | Published ePHPm v0.4 image | ePHPm added a strong clustered OPcache invalidation story. |

For the story, read:

- [docs/ephpm-vs-php-fpm-lab-report.md](docs/ephpm-vs-php-fpm-lab-report.md)
- [docs/follow-up-opcache.md](docs/follow-up-opcache.md)
- [docs/current-findings.md](docs/current-findings.md)

## Repository Layout

| Path | Purpose |
| --- | --- |
| `docs/` | Narrative report, follow-up, and raw findings from the lab. |
| `k8s/` | Kubernetes manifests and k6 jobs for each benchmark phase. |
| `patches/` | Local patch used during the source-built worker-mode phase. |
| `scripts/` | Helper scripts for cloning inputs, building ePHPm, rendering manifests, and running v4 worker tests. |
| `apps/` | Ignored local upstream checkouts created by `scripts/clone-inputs.sh`. Not committed. |

## Important Caveats

This is a reproducible lab, not a universal benchmark.

- The original cluster was a three-node Linode LKE cluster using `g6-standard-1` nodes.
- Kubernetes Metrics API was not installed, so CPU and memory correlation is incomplete.
- Historical docs mention the original LKE node names and a temporary `ttl.sh` image. The committed manifests have been made portable by removing `nodeName` pins and replacing expired image references with placeholders or published tags.
- The older v4 worker result depended on a source-built ePHPm image because the public image available at that time did not expose the worker runtime path we needed. The newer OPcache follow-up uses the published `ephpm/ephpm:v0.4.0-php8.4` image.
- The manifests are intentionally small and self-contained. They generate apps in init containers rather than assuming a long-lived application image.

## What I Would Test Next

If I were turning this into a stronger operator-grade evaluation, I would test:

| Next test | Why it matters |
| --- | --- |
| Larger nodes | The original LKE nodes were small; bigger nodes would show whether the shape holds with more CPU and memory headroom. |
| Metrics API installed for CPU/memory | Latency without resource data is incomplete. I want CPU, memory, restart, and saturation signals. |
| Sustained 10-30 minute runs | The current runs are short. Persistent workers need longer soak tests to expose leaks, drift, and tail behavior. |
| Multiple worker counts | Worker count and concurrency tuning may change the throughput knee and p95/p99 behavior. |
| Redis extension vs Predis | PHP-FPM used Predis/TCP. Testing `phpredis` would make the PHP-FPM cache baseline stronger. |
| Octane/Swoole/RoadRunner/ePHPm comparison | ePHPm should be compared against other persistent-worker PHP runtimes, not only PHP-FPM. |
| Failure/restart behavior for persistent workers | Production confidence depends on how workers behave across crashes, deploys, stale state, and pod restarts. |

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
