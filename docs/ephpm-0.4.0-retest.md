# ePHPm 0.4.0 Retest

Date: 2026-07-09  
Author: Benjamin Pace

## Purpose

This retest reran the earlier v1-v4 benchmark shapes against the published ePHPm image:

```text
ephpm/ephpm:v0.4.0-php8.4
```

The goal was not to invent a friendlier benchmark after the fact. The goal was to keep the previous test shapes recognizable, update ePHPm to the current public image, and record what changed.

## Environment

| Item | Value |
| --- | --- |
| Cluster | Linode LKE |
| Nodes | 3 |
| Kubernetes | v1.36.0 |
| Node class | Small LKE nodes used throughout this lab |
| Metrics API | Not installed |
| Load generator | k6 jobs running inside Kubernetes |
| ePHPm image | `ephpm/ephpm:v0.4.0-php8.4` |
| PHP-FPM image | Official Docker Hub PHP 8.4 FPM variants used by each manifest |

Before retesting v4, older v1/v2/Krayin deployments were scaled down to free CPU and memory. The cluster was small enough that rolling replacements could otherwise leave updated pods Pending.

## Summary

| Test | Shape | Result on 0.4.0 | Operator read |
| --- | --- | --- | --- |
| v1 hello | Tiny PHP endpoint | ePHPm lower avg, PHP-FPM lower p95 | Too small to be decisive. |
| v1 CPU | Small deterministic hash loop | ePHPm wins avg and p95 | 0.4.0 no longer looks worse on this toy route. |
| v2 synthetic app | Front controller, autoload, templates, JSON fixtures | ePHPm wins avg and p95 | Current ePHPm looks solid on this synthetic app-shaped workload. |
| v3 Krayin | Real Laravel CRM in normal request mode | PHP-FPM wins | ePHPm still does not win every framework app in request mode. |
| v3b Krayin worker | Same Krayin path mix in ePHPm worker mode | ePHPm worker improves substantially | Worker mode changes the Krayin story, but this needs a full three-way rerun. |
| v4 Laravel request mode | Synthetic Laravel app, cache-heavy routes | ePHPm slightly wins overall | Request mode is competitive here, but not the main story. |
| v4 Laravel worker/native KV | Persistent worker plus native ePHPm KV | ePHPm wins clearly | This remains the strongest ePHPm shape. |
| v4 rate-160 | Medium-traffic pressure run | ePHPm worker holds target rate; FPM drops heavily | Worker/native-KV architecture is the compelling result. |

## v1: Tiny PHP Routes

Rate shape: gentle k6 scenario, about 16-17 requests/s.

| Route | Runtime | Requests | Failures | HTTP avg | HTTP median | HTTP p95 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `/hello.php` | PHP-FPM + nginx | 1258 | 0 | 2.34 ms | 1.82 ms | 4.18 ms |
| `/hello.php` | ePHPm 0.4.0 | 1260 | 0 | 1.84 ms | 1.30 ms | 5.18 ms |
| `/cpu.php` | PHP-FPM + nginx | 1239 | 0 | 5.16 ms | 4.57 ms | 9.75 ms |
| `/cpu.php` | ePHPm 0.4.0 | 1248 | 0 | 3.81 ms | 2.83 ms | 7.94 ms |

Interpretation: this reverses the original tiny-route result enough to say ePHPm 0.4.0 is not obviously disadvantaged on the toy workload. It is still not a workload worth overclaiming from.

## v2: Synthetic App-Shaped PHP

Rate: `40 iterations/s` for `45s`.

| Runtime | Requests | Failures | App elapsed avg | HTTP avg | HTTP median | HTTP p95 | HTTP max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 1801 | 0 | 292.07 us | 5.30 ms | 2.08 ms | 4.56 ms | 857.43 ms |
| ePHPm 0.4.0 | 1801 | 0 | 263.57 us | 1.68 ms | 1.39 ms | 2.99 ms | 38.25 ms |

Interpretation: ePHPm 0.4.0 won this synthetic app-shaped test. This is a meaningful improvement over the early story, but it is still not a real application benchmark.

## v3: Krayin CRM

Rate target: `8 iterations/s` for `75s`.

| Runtime | Requests | Completed iterations | Dropped iterations | Failures | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 455 | 453 | 148 | 0 | 2.28 s | 2.01 s | 2.88 s | 11.57 s |
| ePHPm 0.4.0 | 343 | 341 | 260 | 0 | 3.19 s | 3.64 s | 5.29 s | 7.36 s |

Interpretation: Krayin still favors PHP-FPM in this lab. Both stacks were functionally correct, but neither sustained the requested 8 rps cleanly on the small cluster. PHP-FPM completed more work with lower average, median, and p95 latency.

This is the most important brake on overclaiming. ePHPm 0.4.0 is improved, but arbitrary Laravel applications in normal request mode should still be tested before making a runtime switch.

## v3b: Krayin CRM Worker Mode

After the request-mode Krayin result, we added a separate ePHPm worker-mode Krayin deployment:

```text
k6 -> Service -> ePHPm worker -> Krayin / Laravel Octane bridge -> MySQL
```

The worker deployment installs `laravel/octane` and `ephpm/octane-driver`, then starts ePHPm with:

```text
mode = "worker"
worker_script = "vendor/bin/ephpm-octane-worker"
worker_count = 4
```

Rate target: `8 iterations/s` for `75s`.

| Runtime | Requests | Completed iterations | Dropped iterations | Failures | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm 0.4.0 worker mode | 545 | 543 | 58 | 0 | 1.31 s | 1.11 s | 2.67 s | 3.37 s |

Interpretation: this is a meaningful improvement over the request-mode ePHPm Krayin result. The request-mode ePHPm run completed 341 iterations with 260 dropped iterations, 3.19 s average latency, and 5.29 s p95. The worker-mode run completed 543 iterations with 58 dropped iterations, 1.31 s average latency, and 2.67 s p95.

Important caveat: this v3b run was performed after scaling the non-target Krayin app deployments down to fit the tiny LKE cluster cleanly. It proves the Krayin worker shape is viable and promising, but the next fair step is a controlled three-way rerun where PHP-FPM, ePHPm request mode, and ePHPm worker mode are each tested sequentially under the same cluster conditions.

## v4: Laravel Cache-Heavy App

This test used a generated Laravel app with bootstrap, dashboard, cache summary, and counter routes. PHP-FPM used Redis through Predis/TCP. ePHPm request mode and ePHPm worker mode used native ePHPm KV.

### Baseline Rate

Rate: `20 iterations/s` for `75s`.

| Runtime | Requests | Iterations | Failures | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx + Redis/Predis | 1512 | 1501 | 0 | 12.12 ms | 9.52 ms | 23.55 ms | 45.77 ms |
| ePHPm 0.4.0 request mode + native KV | 1512 | 1501 | 0 | 11.24 ms | 9.48 ms | 20.69 ms | 34.39 ms |
| ePHPm 0.4.0 worker mode + native KV | 1512 | 1501 | 0 | 6.88 ms | 4.30 ms | 12.15 ms | 57.45 ms |

Interpretation: normal ePHPm request mode was competitive and slightly ahead overall. Worker mode was substantially faster at avg/median/p95, with a worse p99 than request mode in this short run because of a few long bootstrap outliers.

### Rate-160 Pressure Run

Rate: `160 iterations/s` for `45s`.

| Runtime | Requests | Iterations | Iteration rate | Dropped iterations | Failures | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx + Redis/Predis | 4687 | 4676 | 100.02/s | 2525 | 0 | 1.46 s | 1.53 s | 1.75 s | 1.97 s |
| ePHPm 0.4.0 worker mode + native KV | 7190 | 7179 | 159.27/s | 22 | 0 | 28.97 ms | 3.67 ms | 168.82 ms | 396.46 ms |

Interpretation: this is the clearest current win for ePHPm. The worker/native-KV shape stayed close to the requested arrival rate while PHP-FPM + Redis/Predis fell to about 100 iterations/s and dropped far more scheduled work.

The result should still be described carefully. This is not "ePHPm universally beats PHP-FPM." It is "ePHPm becomes compelling when the app and deployment model use persistent workers and native services."

## OPcache Follow-Up

The OPcache cluster follow-up also used `ephpm/ephpm:v0.4.0-php8.4`.

Rate: `50 iterations/s` for `120s`.

| Metric | ePHPm deploy invalidation | PHP-FPM rolling restart |
| --- | ---: | ---: |
| requests | 6001 | 6001 |
| failed | 0 | 0 |
| avg | 1.06 ms | 2.19 ms |
| p95 | 2.47 ms | 5.57 ms |
| p99 | 5.98 ms | 13.63 ms |
| max | 21.75 ms | 40.50 ms |

Interpretation: this is an operational-shape win. ePHPm invalidated OPcache across the cluster with one deploy signal. PHP-FPM used a rolling restart to get equivalent cache-busting behavior in this lab.

## What Still Needs Retesting

The current 0.4.0 pass sharpened the story, but it also exposed the next gaps:

| Gap | Why it matters |
| --- | --- |
| Larger nodes | The Krayin test was constrained enough that both runtimes dropped iterations. |
| Metrics API | CPU and memory data are needed to explain whether latency comes from CPU saturation, memory pressure, process overhead, or Redis/TCP overhead. |
| Redis extension baseline | PHP-FPM should be retested with `phpredis`, not only Predis/TCP. |
| Full Krayin three-way rerun | v3b shows worker mode is promising, but PHP-FPM, request mode, and worker mode should be retested sequentially under the same cluster conditions. |
| Longer runs | Persistent workers need 10-30 minute soak tests to catch leak/drift behavior. |
| Multiple worker counts | The ePHPm worker pool may have a different sweet spot than this first configuration. |
| WordPress and Drupal | CMS/plugin behavior is where many real PHP operators live. |
| Symfony and Laravel Octane alternatives | ePHPm should be compared with other persistent-worker runtimes too, not only PHP-FPM. |
| Restart/failure behavior | Production confidence depends on deploys, crashes, stale state, and recovery, not just latency. |
