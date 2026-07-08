# ePHPm vs PHP-FPM Lab Report

Author: Benjamin Pace  
Date: 2026-07-07  
Environment: Linode LKE, Kubernetes, k6, Laravel, PHP 8.4

## Executive Summary

I set out to compare the official Docker Hub PHP-FPM image against ePHPm in a small Kubernetes lab. The goal was not to punish a shared LKE cluster or produce a grand production benchmark. I wanted a fair, repeatable, progressively more realistic comparison that could answer one practical question:

> Can ePHPm beat plain old PHP-FPM in a workload that resembles a real PHP application?

The answer became more nuanced than the marketing promise.

At first, ePHPm did not beat PHP-FPM. In the smallest synthetic tests, PHP-FPM plus nginx was as fast or faster. In a more realistic Krayin CRM test, normal ePHPm server mode was dramatically slower. Even in a purpose-built Laravel cache workload, public `ephpm/ephpm:8.4` in normal request mode lost badly to PHP-FPM plus Redis.

The story changed only after I tested the architecture ePHPm appears to be designed around: persistent worker mode plus native ePHPm KV. The published Docker image was not enough for that test, so I built ePHPm from source. Once the source-built worker runtime was running, ePHPm produced the first clear win of the lab.

At a gentle `20 iterations/s`, ePHPm worker mode was roughly `2.4x` faster on average HTTP latency and had a much better p99. At a quick medium-traffic `160 iterations/s` test, ePHPm mostly sustained the requested arrival rate while PHP-FPM fell behind badly.

That does not mean ePHPm won every dimension. It means ePHPm has a real performance story, but that story depends on using the right application shape and the right deployment model. My biggest feedback is not "ePHPm is slow." My biggest feedback is that a user can easily test the wrong mode, draw the wrong conclusion, and never reach the path where ePHPm starts to make sense.

If the creator of ePHPm had specifically asked me to evaluate it, I would frame the result this way:

> ePHPm should not be presented as a drop-in faster PHP server for arbitrary PHP projects. It is more compelling as an application runtime for projects that can adapt to persistent workers and native runtime services.

That positioning is narrower, but stronger. It also gives users a clearer path to success.

## Cluster And Test Shape

I ran the tests on a small LKE cluster.

| Item | Value |
| --- | --- |
| Kubernetes provider | Linode LKE |
| Nodes | 3 |
| Node type | `g6-standard-1` |
| Per-node allocatable CPU | About `940m` |
| Per-node allocatable memory | About `1.34Gi` |
| Load tool | k6 |
| Main namespace | `php-bench`, later `laravel-v4` |
| Metrics API | Not installed |

The missing Metrics API mattered. I could run the workloads and measure request behavior, but I could not capture clean `kubectl top pods` or `kubectl top nodes` CPU/memory snapshots.

## Guiding Principles

I tried to keep the test honest.

| Principle | How I applied it |
| --- | --- |
| Compare separate runtimes | I verified Services, selectors, Pod IPs, response headers, and PHP versions. |
| Start gentle | I avoided noisy-neighbor behavior and used fixed-rate k6 tests. |
| Increase realism gradually | I moved from tiny PHP scripts to an app-shaped PHP harness, then Krayin CRM, then Laravel with cache behavior. |
| Do not overclaim | I documented when a result was synthetic, incomplete, or unfavorable. |
| Follow the repo's actual claims | After weak early results, I re-read the ePHPm docs and focused on worker mode and native KV. |

## Evaluator Bias Note

I came into this biased toward PHP-FPM.

That matters because PHP-FPM has earned a lot of trust. It is familiar, stable, easy to deploy, easy to reason about, and extremely good at the boring job most PHP production stacks ask it to do. When ePHPm behaved differently from PHP-FPM, my first instinct was to treat that as a risk.

That bias is useful in one way: many production operators will react the same way. If ePHPm wants to win those users over, it has to do more than produce a good benchmark. It has to make the correct deployment path obvious, make PHP version support predictable, and make the tradeoffs feel intentional rather than surprising.

So I tried to read the results through two lenses:

| Lens | Question |
| --- | --- |
| PHP-FPM operator | Would I trust this in production instead of my known-good stack? |
| ePHPm evaluator | Did I test the runtime in the mode where it is actually designed to win? |

The first lens made me skeptical. The second lens is what eventually found the worker-mode win.

## v1: Tiny PHP Script Harness

The first harness used the same tiny PHP scripts mounted into both runtimes.

| Runtime | Container shape |
| --- | --- |
| PHP-FPM | `nginx:1.27-alpine` plus official `php:8.4-fpm-alpine` |
| ePHPm | `ephpm/ephpm:8.4` |

The total resource envelope was equal:

| Runtime | CPU limit | Memory limit |
| --- | ---: | ---: |
| PHP-FPM + nginx | `250m` | `320Mi` |
| ePHPm | `250m` | `320Mi` |

Routes:

| Route | Purpose |
| --- | --- |
| `/hello.php` | Minimal JSON response |
| `/cpu.php` | Deterministic SHA-256 loop |
| `/json.php` | Small JSON encode/decode workload |

Before trusting the numbers, I verified that k6 was actually hitting the separate pods.

| Runtime | Evidence |
| --- | --- |
| PHP-FPM + nginx | Service selected `app=php-fpm-nginx`, response server was `nginx/1.27.5`, PHP was `8.4.23` |
| ePHPm | Service selected `app=ephpm`, response server was `ePHPm/0.1.0`, PHP was `8.4.22` |

One useful discovery: direct ePHPm Pod-IP access required `Host: ephpm`, because its default trusted-host behavior rejected raw IP hosts with `421 Misdirected Request`.

### v1 Result

The first polite run was too gentle because the k6 script included `sleep(0.2)`, limiting throughput around `16-17 req/s`.

The corrected inspect run used a fixed `50 req/s` target.

| Fixed 50 req/s | Runtime | HTTP avg | HTTP median | HTTP p95 | App/script avg |
| --- | --- | ---: | ---: | ---: | ---: |
| `/hello.php` | PHP-FPM + nginx | 1.12ms | 1.03ms | 1.55ms | 2.0us |
| `/hello.php` | ePHPm | 1.29ms | 1.09ms | 2.57ms | 2.11us |
| `/cpu.php` | PHP-FPM + nginx | 2.80ms | 2.53ms | 3.98ms | 1.53ms |
| `/cpu.php` | ePHPm | 3.19ms | 2.72ms | 6.74ms | 1.87ms |

My read: v1 did not show an ePHPm advantage. PHP-FPM was slightly ahead on both tiny routes.

## v1 Caveats

The v1 result was valid for what it tested, but it was not a deep ePHPm test.

| Caveat | Why it mattered |
| --- | --- |
| PHP versions differed | PHP-FPM returned `8.4.23`; ePHPm returned `8.4.22`. |
| PHP builds differed | PHP-FPM used non-thread-safe PHP; ePHPm used embedded ZTS PHP. |
| OPcache differed | ePHPm reported OPcache disabled in its embedded SAPI. |
| Workload was tiny | The routes did not resemble a real PHP app. |
| No CPU/memory metrics | Metrics API was not available. |

## v2: App-Shaped Synthetic PHP

For v2, I built a small app-shaped PHP workload.

Files:

| File | Purpose |
| --- | --- |
| `k8s/php-benchmark-v2.yaml` | Runtime deployment |
| `k8s/k6-v2-php-fpm.yaml` | PHP-FPM k6 job |
| `k8s/k6-v2-ephpm.yaml` | ePHPm k6 job |

The v2 app included:

| Feature | Included |
| --- | --- |
| Front controller | Yes |
| Autoloaded classes | Yes |
| Repository class | Yes |
| View renderer class | Yes |
| JSON fixture reads | Yes |
| Filtering and sorting | Yes |
| HTML and API routes | Yes |
| Laravel framework | No |
| Composer dependency graph | No |
| Database/cache/session layer | No |
| ePHPm worker mode | No |

### v2 Result

| Runtime | Requests | Failed | HTTP avg | HTTP median | HTTP p95 | App elapsed avg | App elapsed p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 1801 | 0 | 1.68ms | 1.40ms | 3.62ms | 178.19us | 239.86us |
| ePHPm | 1801 | 0 | 2.00ms | 1.76ms | 3.51ms | 622.88us | 831.86us |

My read: ePHPm still did not outperform PHP-FPM. The p95 HTTP number was close, but PHP-FPM had better average, median, and measured application elapsed time.

## Re-Reading The ePHPm Claims

At this point, the results were disappointing enough that I went back to the ePHPm repo and docs. That was the right move.

The strongest ePHPm claims were not about tiny normal request handling. They centered around:

| ePHPm capability | Why it could matter |
| --- | --- |
| Worker mode | Boot a framework once and serve many requests from a persistent worker. |
| Native KV/cache functions | Avoid external Redis/Predis/TCP overhead. |
| DB connection pooling | Avoid repeated connection setup. |
| Integrated runtime services | Move common app infrastructure closer to the PHP runtime. |

That changed the testing direction. The real question was no longer "does public `ephpm/ephpm:8.4` beat PHP-FPM on tiny scripts?" It became "can ePHPm win when I use the architecture it is actually pitching?"

## v3: Krayin CRM

For v3, I tried a real Laravel application: Krayin CRM.

| Item | Value |
| --- | --- |
| App | Krayin CRM |
| Repo | `https://github.com/krayin/laravel-crm` |
| Commit | `7d426f901b18f043eb91e425c7bdd3e9cba568ab` |
| Local path | `apps/laravel-crm` |
| Database | `mysql:8.4` |
| Login user | `admin@example.com` |

Files:

| File | Purpose |
| --- | --- |
| `k8s/krayin-v3.yaml` | Krayin deployments and MySQL |
| `k8s/k6-v3-php-fpm.yaml` | PHP-FPM k6 job |
| `k8s/k6-v3-ephpm.yaml` | ePHPm k6 job |

The k6 script logged in and rotated through admin dashboard, dashboard stats, leads, lead kanban data, contacts, products, users, and quotes.

### v3 Compatibility Issues

This test exposed practical compatibility problems before the benchmark even mattered.

| Issue | Impact | Workaround |
| --- | --- | --- |
| `mb_split()` missing | Laravel 12 calls `mb_split()` through `Illuminate\Support\Str`. | Added a guarded compatibility shim. |
| `$_SERVER['PHP_SELF']` missing in ePHPm paths | Some CLI/server behavior did not match normal PHP expectations. | Shimmed where needed. |
| `ephpm php artisan ...` was unreliable for install flow | It printed command lists or failed instead of reliably running installer steps. | Used official PHP CLI for install/migration jobs. |
| Krayin installer used production-unsafe migration flow | `migrate:fresh` without `--force` was blocked under production env. | Ran underlying migration/seeding commands directly with `--force`. |

### v3 Result

Rate target was a gentle `8 req/s` for `75s`.

| Runtime | HTTP requests | Iterations | Dropped iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 596 | 594 | 7 | 639.82ms | 662.61ms | 1.36s | 1.90s |
| ePHPm normal mode | 114 | 112 | 489 | 11.06s | 11.25s | 17.50s | 18.02s |

My read: this was a real app-shaped result, and it was unfavorable to ePHPm in normal server mode. PHP-FPM sustained the target almost completely. ePHPm stayed correct, but it did not sustain the arrival rate.

This still did not test ePHPm worker mode.

## v4: Straight Laravel Plus Cache

For v4, I moved away from Krayin and built a purpose-shaped Laravel workload. The point was to isolate the thing ePHPm should be good at: a persistent Laravel-ish workload with cache-heavy routes.

Files:

| File | Purpose |
| --- | --- |
| `k8s/laravel-v4.yaml` | Laravel v4 app deployments |
| `k8s/k6-v4-php-fpm.yaml` | PHP-FPM k6 job |
| `k8s/k6-v4-ephpm.yaml` | ePHPm normal-mode k6 job |

Runtime shape:

| Runtime | Cache path |
| --- | --- |
| PHP-FPM + nginx | Redis via Predis/TCP |
| ePHPm normal mode | Native ePHPm KV SAPI |

Routes:

| Route | Mix | Purpose |
| --- | ---: | --- |
| `/api/bootstrap` | 20% | Framework/bootstrap-ish JSON route |
| `/dashboard` | 20% | HTML/dashboard route |
| `/api/cache-summary` | 40% | Cache-heavy summary route |
| `/api/counter` | 20% | Incrementing KV/counter route |

The first v4 attempt used Predis against ePHPm's Redis-compatible RESP listener. That path went poorly: the pod was OOMKilled and k6 saw many failures and dropped iterations. After re-reading the ePHPm docs, I switched the ePHPm app path to native KV functions such as `ephpm_kv_get`, `ephpm_kv_set`, `ephpm_kv_expire`, `ephpm_kv_del`, and `ephpm_kv_incr`.

The ePHPm logs then confirmed:

| Log line | Meaning |
| --- | --- |
| `KV store wired to PHP native functions` | The native SAPI function path was active. |
| `KV store RESP server listening` | The Redis-compatible listener was also present. |

### v4 Normal Mode Result

Rate target was `20 iterations/s` for `75s`.

| Runtime | Cache path | HTTP requests | Iterations | Dropped iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 0 | 11ms | 8.61ms | 19.66ms | 45.09ms |
| ePHPm normal mode | Native ePHPm KV SAPI | 356 | 345 | 1156 | 8.66s | 8.58s | 12.04s | 15.12s |

My read: native KV made ePHPm more stable than the Predis/RESP attempt, but it did not make normal ePHPm server mode competitive. PHP-FPM plus Redis still dominated.

## v4 Worker-Mode Attempt With Public Image

The next step was obvious: test worker mode.

The documented ePHPm Laravel/Octane path required:

| Requirement | Detail |
| --- | --- |
| Laravel Octane | Install `laravel/octane`. |
| ePHPm worker packages | Install `ephpm/octane-driver` and `ephpm/worker`. |
| ePHPm config | Set `[php] mode = "worker"`. |
| Document root | Point at the Laravel project root, not `public/`. |
| Worker script | `vendor/bin/ephpm-octane-worker`. |
| App base | `EPHPM_APP_BASE=/var/www/html`. |

I got the Composer install path working by pinning Laravel to `^12.0` and resolving the ePHPm worker packages from GitHub tag ZIP archives instead of SSH clones.

But the public Docker image still blocked the benchmark.

| Observation | Result |
| --- | --- |
| `ephpm/ephpm:8.4` version | Reported `ephpm 0.2.0`. |
| `ephpm/ephpm:latest` version | Also reported `ephpm 0.2.0`. |
| Documentation claim | Laravel worker mode appeared to require ePHPm `3.0`. |
| Pod behavior | ePHPm started, but readiness checks returned `404`. |

My read: this was not a worker-mode performance result. It was a runtime availability and packaging result. The documented worker path did not appear testable with the currently published Docker image.

## v4 Worker Mode From Source

To actually test worker mode, I built ePHPm from source.

| Item | Value |
| --- | --- |
| Repo | `https://github.com/ephpm/ephpm` |
| Commit | `469c51e` |
| Commit title | `fix: review follow-ups (ratelimit TTL, ext ini-injection, jwt float-exp, docs) (#127)` |
| Local image | `lke-lab/ephpm:source-469c51e` |
| Temporary LKE pull image | Ephemeral `ttl.sh` image, now expired |
| Smoke test | `ephpm source-469c51e` |

The source build needed several local fixes.

| Area | What I had to change |
| --- | --- |
| PHP SDK | Used the repo-pinned PHP SDK `8.4.22`. |
| Rust | Used stable Rust because dependencies needed newer compiler support. |
| Linking | Used GNU `bfd` instead of the Rust self-contained `lld` path. |
| Resolver symbols | Added a compatibility shim for legacy glibc resolver symbols. |
| Worker package metadata | Corrected over-escaped PSR-4 namespaces in generated package metadata. |
| Worker script load path | Added a narrow `require_once` for `vendor/ephpm/worker/src/Runtime.php`. |

Files touched for the local source-build path:

| File | Purpose |
| --- | --- |
| `apps/ephpm/docker/Dockerfile` | Build image adjustments |
| `apps/ephpm/crates/ephpm/build.rs` | Link/build fixes |
| `apps/ephpm/crates/ephpm-php/build.rs` | Resolver shim compilation |
| `apps/ephpm/crates/ephpm-php/resolver_compat.c` | Resolver compatibility shim |
| `k8s/laravel-v4.yaml` | Laravel worker deployment fixes |

After this, the source-built worker deployment rolled out successfully.

## First Clear ePHPm Victory

At `20 iterations/s` for `75s`, source-built ePHPm worker mode finally beat PHP-FPM.

| Runtime | Cache path | HTTP requests | Iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | Native ePHPm KV SAPI | 1512 | 1501 | 4.71ms | 3.90ms | 10.16ms | 16.66ms | 0 |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 11.33ms | 9.02ms | 19.75ms | 44.13ms | 0 |

Relative deltas:

| Metric | ePHPm worker | PHP-FPM | ePHPm result |
| --- | ---: | ---: | ---: |
| HTTP avg | 4.71ms | 11.33ms | 2.41x faster |
| HTTP median | 3.90ms | 9.02ms | 2.31x faster |
| HTTP p95 | 10.16ms | 19.75ms | 1.94x faster |
| HTTP p99 | 16.66ms | 44.13ms | 2.65x faster |
| HTTP max | 38.18ms | 160.45ms | 4.20x faster |

Per-route view:

| Runtime | bootstrap avg/p95 | dashboard avg/p95 | cache-summary avg/p95 | counter avg/p95 |
| --- | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 5.36ms / 12.44ms | 6.13ms / 13.80ms | 3.87ms / 6.83ms | 4.22ms / 9.73ms |
| PHP-FPM + nginx | 8.54ms / 10.82ms | 8.98ms / 11.40ms | 10.34ms / 17.69ms | 18.97ms / 43.95ms |

The most interesting route was `/api/counter`.

| Endpoint metric | ePHPm worker | PHP-FPM | ePHPm result |
| --- | ---: | ---: | ---: |
| `/api/counter` avg | 4.22ms | 18.97ms | 4.50x faster |
| `/api/counter` p95 | 9.73ms | 43.95ms | 4.52x faster |
| `/api/counter` p99 | 15.40ms | 130.96ms | 8.51x faster |

My read: this was the first result that supported ePHPm's performance story in the lab. The win appeared where the architecture should help: persistent Laravel worker mode plus native KV, avoiding both per-request PHP-FPM handoff and Redis/Predis round trips.

## Rate-8 Medium-Traffic Quick Test

After the first win, I ran a quick "crank it to 8" test.

| Item | Value |
| --- | --- |
| Previous gentle v4 rate | `20 iterations/s` |
| Rate-8 target | `160 iterations/s` |
| Duration | `45s` |
| Scenario | k6 `constant-arrival-rate` |
| Scheduled measured iterations | About `7200` |
| Route mix | Same v4 Laravel/KV mix |

Important fairness note: my first rate-8 attempt accidentally applied both k6 jobs at the same time. I treated that as a contaminated shakedown and discarded it for the side-by-side comparison. The recorded comparison came from sequential runs.

Files:

| File | Purpose |
| --- | --- |
| `k8s/k6-v4-rate8.yaml` | Shared k6 script/config |
| `k8s/k6-v4-rate8-ephpm-worker.yaml` | ePHPm-only rate-8 job |
| `k8s/k6-v4-rate8-php-fpm.yaml` | PHP-FPM-only rate-8 job |

### Rate-8 Result

| Runtime | Target rate | Completed iterations | Iteration rate | Dropped iterations | HTTP requests | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | HTTP max | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 160/s | 7091 | 156.53/s | 110 | 7102 | 141.82ms | 3.83ms | 819.08ms | 1.23s | 1.37s | 0 |
| PHP-FPM + nginx + Redis | 160/s | 4744 | 101.79/s | 2457 | 4755 | 1.44s | 1.49s | 1.72s | 2.50s | 2.57s | 0 |

Completion view:

| Runtime | Scheduled iterations completed | Scheduled iterations dropped |
| --- | ---: | ---: |
| ePHPm source worker mode | 98.5% | 1.5% |
| PHP-FPM + nginx + Redis | 65.9% | 34.1% |

Endpoint tails:

| Runtime | bootstrap p95/p99 | dashboard p95/p99 | cache-summary p95/p99 | counter p95/p99 |
| --- | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 852.95ms / 1.28s | 424.80ms / 782.14ms | 836.26ms / 1.30s | 884.70ms / 982.47ms |
| PHP-FPM + nginx + Redis | 1.64s / 1.83s | 1.77s / 2.53s | 1.73s / 2.50s | 1.92s / 2.52s |

My read: ePHPm also showed pressure at rate-8. Its p95 and p99 became ugly compared with the gentle run. But it mostly kept up with the requested arrival rate. PHP-FPM stayed error-free, but it could not sustain the scheduled rate; k6 dropped `2457` iterations and effective throughput fell to about `102 iterations/s`.

The median tells the story: ePHPm's median stayed at `3.83ms`, while PHP-FPM's median moved to `1.49s`. ePHPm had intermittent tail spikes; PHP-FPM spent most of the run backed up.

## Operator Positioning

The headline should not be "ePHPm beats PHP-FPM."

The more accurate headline is:

> ePHPm can beat PHP-FPM when the app and deployment model are adapted to ePHPm's worker/native-service architecture.

That wording matters. In this lab, ePHPm did not win as a drop-in replacement for an arbitrary PHP app. It won after I changed the deployment shape to match what ePHPm is trying to be: a persistent PHP application runtime with native services.

## Should I Use ePHPm?

| Situation | Practical answer | Operator note |
| --- | --- | --- |
| Drop-in replacement for arbitrary PHP app | Probably no | The lab results do not support treating ePHPm as a generic faster PHP-FPM swap. |
| Normal request mode against PHP-FPM | PHP-FPM likely wins | PHP-FPM plus nginx is mature, predictable, and very fast for ordinary per-request PHP. |
| Laravel/Octane-style persistent worker | Worth testing | This is where ePHPm finally showed a clear advantage. |
| Cache-heavy app using native ePHPm KV | Strongest case | The biggest win came from persistent worker mode plus native KV/cache behavior. |
| Need boring production certainty today | PHP-FPM still king | PHP-FPM has the stronger operational track record and release predictability. |

## Winning Architecture Shape

The winning ePHPm path was:

```text
k6 -> Service -> ePHPm worker -> native KV
```

The PHP-FPM comparison path was:

```text
k6 -> Service -> nginx -> PHP-FPM -> Predis/TCP -> Redis
```

This is not a small implementation detail. It is the core finding. ePHPm became compelling when the application stopped treating it like a simple request server and started using its worker/native-service model.

## What I Would Test Next

| Next test | Why it matters |
| --- | --- |
| Larger nodes | The original LKE nodes were small; larger nodes would show whether the same shape holds with more headroom. |
| Metrics API installed for CPU/memory | Request latency needs resource context to explain saturation. |
| Sustained 10-30 minute runs | Persistent workers need soak testing for leaks, stale state, and tail drift. |
| Multiple worker counts | Worker tuning may materially change throughput and p95/p99 behavior. |
| Redis extension vs Predis | Testing `phpredis` would strengthen the PHP-FPM cache baseline. |
| Octane/Swoole/RoadRunner/ePHPm comparison | ePHPm should be compared against other persistent-worker PHP runtimes too. |
| Failure/restart behavior for persistent workers | Production adoption depends on crash, deploy, restart, and stale-state behavior. |

## Overall Timeline

| Phase | Workload | ePHPm mode | Result |
| --- | --- | --- | --- |
| v1 | Tiny scripts | Public image, normal mode | PHP-FPM slightly ahead |
| v2 | App-shaped synthetic PHP | Public image, normal mode | PHP-FPM ahead |
| v3 | Krayin CRM | Public image, normal mode | PHP-FPM strongly ahead |
| v4 normal | Laravel + cache | Public image, normal mode + native KV | PHP-FPM strongly ahead |
| v4 worker attempt | Laravel + cache | Public image, worker config | Blocked by runtime/package mismatch |
| v4 source worker | Laravel + cache | Source-built worker mode + native KV | ePHPm clear win |
| v4 rate-8 | Laravel + cache | Source-built worker mode + native KV | ePHPm sustained far more load |

## What Worked

| Area | What worked | Why it mattered |
| --- | --- | --- |
| Runtime verification | I confirmed Services, Pod IPs, response headers, and PHP versions. | This kept the comparison from being accidentally self-referential. |
| Incremental workload design | I moved from tiny scripts to app-shaped code to Laravel. | Each phase answered a narrower question before moving on. |
| k6 fixed-rate tests | Constant arrival rate made dropped iterations visible. | This showed when a runtime could not keep up, not just how long successful requests took. |
| Native ePHPm KV | Switching from Predis/RESP to native SAPI functions improved ePHPm stability. | It aligned the test with ePHPm's intended architecture. |
| Re-reading the docs | The weak early results forced me to revisit the repo claims. | That led directly to worker mode, which was the key missing test. |
| Source-built worker runtime | Building from source unlocked the documented worker path. | This produced the first real ePHPm win. |

## What Did Not Work

| Area | What did not work | Impact |
| --- | --- | --- |
| Tiny synthetic benchmarks | They did not expose ePHPm's intended strengths. | PHP-FPM looked equal or better. |
| Normal ePHPm request mode | It lost badly on Krayin and Laravel cache workloads. | A user treating ePHPm as a simple drop-in server could conclude the project is slower than PHP-FPM. |
| Predis against ePHPm RESP | The first v4 cache attempt caused instability and OOM behavior. | Native KV was required for a fair ePHPm-favorable cache path. |
| Public Docker image worker test | The published image reported `ephpm 0.2.0`, while docs pointed at `3.0` worker behavior. | I could not benchmark worker mode from the public image. |
| ePHPm CLI compatibility | `ephpm php artisan ...` did not behave like official PHP CLI for Krayin setup. | Install/migration tasks had to use official PHP CLI. |
| Observability | Metrics API was missing. | I could not correlate latency with CPU/memory pressure. |

## Production Adoption Concerns

If I were considering ePHPm for production, my main fear would not be the peak benchmark number. My main fear would be operational commitment.

PHP-FPM is boring in the best possible way. It tracks PHP releases, works with the dominant deployment model, has well-understood failure modes, and lets most PHP applications run without asking them to become a different kind of application. ePHPm is more ambitious than that, but ambition creates adoption risk.

| Concern | Why it matters in production | What would reduce the risk |
| --- | --- | --- |
| PHP version lag | Teams may be locked to an older PHP patch or minor version if ePHPm images trail upstream PHP. Security updates and framework requirements can force PHP upgrades quickly. | Publish a clear PHP support matrix, release cadence, and security update policy. |
| Runtime feature mismatch | Docs referenced behavior that the public image did not appear to provide. This makes it hard to know which features are production-ready. | Tie docs to exact image tags and runtime versions. |
| Drop-in expectations | Many users will try ePHPm like nginx + PHP-FPM: point it at an app and expect speed. That path may not show benefits. | Be explicit that worker mode and native integrations are where performance gains are expected. |
| Framework compatibility | Laravel exposed missing functions, CLI differences, path assumptions, and package metadata issues. | Maintain framework-specific compatibility guides and smoke-tested example apps. |
| Operational observability | I could measure request latency, but not enough runtime internals. | Provide Prometheus metrics, queue depth, worker state, KV memory use, and error counters. |
| Vendor/runtime lock-in | Native KV and worker mode can be valuable, but apps may become tied to ePHPm-specific APIs. | Provide framework adapters and graceful fallbacks to Redis/PHP-FPM-compatible paths. |

This is where ePHPm needs the most product work. The performance idea is interesting, but production users need confidence that they can upgrade PHP, debug incidents, and leave the runtime if they have to.

## Documentation Feedback

The documentation should steer users toward the path where ePHPm can actually shine. Right now, a motivated user can wander into several losing tests before reaching the correct deployment model.

| Documentation gap | What happened in the lab | Suggested improvement |
| --- | --- | --- |
| Worker mode positioning | I initially tested normal request mode and saw poor results. The better result only came later with worker mode. | State early that major performance benefits are expected primarily from worker mode, not generic request mode. |
| Public image expectations | The public image appeared behind the documented worker-mode story. | Add a compatibility table mapping docs, image tags, ePHPm versions, PHP versions, and supported features. |
| Native KV vs RESP | Predis against the RESP listener was a bad path in this test. Native KV was the intended path. | Explain the performance hierarchy: native KV first, RESP for compatibility, external Redis when portability matters. |
| Laravel setup | Worker mode required precise Composer, path, document-root, and environment details. | Provide a complete Kubernetes-ready Laravel worker example. |
| Unsupported or weak-fit apps | It was not obvious which PHP applications should avoid ePHPm or expect little benefit. | Add a "good fit / poor fit" section to the README. |
| Benchmark claims | It was easy to compare the wrong architecture and get disappointing numbers. | Publish benchmark recipes that compare against realistic PHP-FPM baselines with OPcache and Redis. |

The most useful README change would be direct and plain:

> For traditional per-request PHP applications, ePHPm may not outperform PHP-FPM. ePHPm's main performance benefits come from persistent worker mode and native runtime services such as KV/cache and connection pooling.

That sentence would have saved time and would make the project feel more trustworthy, not less.

## Application Fit

The biggest lesson from the lab is that ePHPm is not equally suited to every PHP workload.

### Likely Good Fits

| Application shape | Why ePHPm could help |
| --- | --- |
| Laravel/Symfony apps that can run safely in persistent worker mode | Framework boot cost can be amortized across many requests. |
| API services with hot routes and repeated dependency setup | Persistent workers reduce repeated initialization overhead. |
| Cache-heavy applications willing to use native ePHPm KV | Avoiding Redis/Predis/TCP can reduce latency and tail behavior. |
| Apps with predictable code and disciplined request state handling | Persistent workers reward applications that avoid leaking per-request state. |
| Internal services where runtime-specific optimization is acceptable | Teams can trade portability for performance when they control the stack. |
| Greenfield PHP services | It is easier to design around ePHPm's model from the start. |

### Poor Or Risky Fits

| Application shape | Why it may not benefit |
| --- | --- |
| Arbitrary legacy PHP apps | They may assume per-request process isolation and standard PHP-FPM behavior. |
| WordPress-style plugin ecosystems | Unknown plugin state, globals, and lifecycle assumptions are risky in persistent workers. |
| Apps that cannot tolerate runtime-specific APIs | Native KV and worker integration can create portability concerns. |
| Apps that depend heavily on exact PHP extension behavior | Missing functions or embedded-SAPI differences can create surprises. |
| Teams needing newest PHP releases immediately | ePHPm must prove it can track PHP releases quickly. |
| Simple static-ish PHP endpoints | PHP-FPM is already extremely fast for tiny routes. |

### Conditional Fits

| Application shape | Condition for success |
| --- | --- |
| Existing Laravel apps | Best if they already run cleanly under Octane-style persistent workers. |
| Database-heavy apps | ePHPm needs a proven DB pooling story and clear operational guidance. |
| Cache-heavy apps | Best if they can use an official ePHPm cache driver rather than hand-written native calls. |
| High-traffic APIs | Need rate-ladder testing, memory profiling, and worker lifecycle validation first. |

## Who Would Really Benefit

The people who benefit most from ePHPm are probably not teams looking for a zero-effort replacement for PHP-FPM. The best audience is more specific.

| User/team | Why they benefit | What they need from ePHPm |
| --- | --- | --- |
| Performance-minded Laravel teams | They can exploit persistent workers and reduce framework boot overhead. | A stable Laravel worker path, Octane guidance, and cache/session adapters. |
| API platform teams | They often have predictable routes, hot code paths, and measurable latency goals. | Observability, concurrency tuning, and deployment examples. |
| Teams already considering Octane/RoadRunner/Swoole-style deployments | They understand persistent worker tradeoffs. | Clear comparison docs and migration guidance. |
| Greenfield service teams | They can design around native KV and runtime services from day one. | Stable APIs and version guarantees. |
| Edge/internal platform builders | They may value a compact integrated runtime. | Reproducible builds, image support, and operational metrics. |
| Experimenters and framework/runtime researchers | ePHPm gives them a serious playground for embedded PHP runtime ideas. | Better source build docs and examples. |

The least likely beneficiary is the average PHP user who has an existing app, a Dockerfile, nginx, PHP-FPM, Redis, OPcache, and a desire to change as little as possible. That user may test ePHPm in normal mode, see worse numbers, and leave.

That is not necessarily a failure of ePHPm. It means the project should be clear about its intended customer.

## How ePHPm Can Be Improved

### Packaging And Release Alignment

| Improvement | Why it matters |
| --- | --- |
| Publish Docker images that match documented worker-mode features. | The docs pointed toward worker mode, but the public image did not appear to contain the needed runtime. |
| Make the image version obvious and consistent. | Seeing `ephpm 0.2.0` in both `8.4` and `latest` made it hard to know what was actually testable. |
| Provide a Laravel worker image example that runs end-to-end. | A working reference image would remove a lot of integration guesswork. |
| Publish a PHP version support policy. | Production users need to know whether they can keep up with PHP security and framework requirements. |
| Separate stable and experimental features in image tags. | Users should not have to infer maturity from source history. |

### Laravel And Composer Integration

| Improvement | Why it matters |
| --- | --- |
| Fix package metadata escaping for PSR-4 namespaces. | Over-escaped Composer prefixes broke worker package autoloading. |
| Publish installable package tags through normal Composer paths. | Requiring GitHub ZIP overrides made the deployment more fragile. |
| Provide a maintained Laravel 12 example app. | Laravel version compatibility matters, and the installer can float to incompatible versions. |
| Document the exact `document_root`, `worker_script`, and env requirements together. | Worker mode is sensitive to path layout. |
| Provide official Laravel cache/session/queue guidance. | Users need to know when to use ePHPm-native services and when to keep Redis/database-backed infrastructure. |
| Add an Octane compatibility checklist. | Existing Laravel apps need a way to assess persistent-worker readiness before migrating. |

### Runtime Compatibility

| Improvement | Why it matters |
| --- | --- |
| Make `ephpm php artisan` behave like standard PHP CLI where possible. | Laravel install, migration, and cache commands expect normal CLI behavior. |
| Populate common `$_SERVER` values consistently. | Missing `PHP_SELF` caused framework compatibility issues. |
| Include mbregex support or document its absence loudly. | Laravel called `mb_split()`, which was missing. |
| Provide a compatibility checklist for Laravel apps. | This would separate expected limitations from bugs. |
| Document embedded-SAPI differences from FPM/CLI. | Users need to know which PHP assumptions may not hold. |
| Offer a conformance smoke-test script. | A command like `ephpm doctor laravel` could catch missing functions, path issues, and worker setup problems. |

### Native KV And Cache Story

| Improvement | Why it matters |
| --- | --- |
| Provide an official Laravel cache driver for ePHPm KV. | Hand-written `ephpm_kv_*` route helpers are fine for a lab, but not for real apps. |
| Document when to use native KV vs RESP. | The Predis/RESP path was dramatically worse in this lab. |
| Expose KV behavior, limits, eviction, persistence, and memory accounting clearly. | Native KV is central to the win, so operators need to understand it. |
| Provide portability fallbacks. | Apps should be able to use Redis locally or in fallback mode without major rewrites. |
| Document failure modes. | Operators need to know what happens to KV state on pod restart, OOM, rollout, or scale-out. |

### Build And Source Developer Experience

| Improvement | Why it matters |
| --- | --- |
| Keep the source Dockerfile buildable against current Rust stable. | I needed build/linker adjustments before getting a usable image. |
| Avoid fragile linker defaults. | The build needed GNU `bfd` instead of the self-contained `lld` path. |
| Resolve PHP static resolver symbols in the build. | I had to add a compatibility shim for legacy resolver symbols. |
| Publish reproducible build instructions for PHP 8.4. | A documented worker-mode source build would make testing much easier. |
| Make source builds produce clearly versioned images. | A user should be able to tie a benchmark result to an exact runtime version. |
| Add CI coverage for the documented Docker build path. | If the docs say it builds, CI should prove it. |

### Performance And Observability

| Improvement | Why it matters |
| --- | --- |
| Expose runtime metrics suitable for Kubernetes scraping. | Latency alone is not enough to diagnose saturation. |
| Document worker concurrency and queue behavior. | At rate-8, ePHPm kept up but had large tail spikes. |
| Provide recommended k6/benchmark profiles. | This would help users avoid testing the wrong runtime mode. |
| Publish comparisons against PHP-FPM with OPcache and Redis. | That is the real baseline ePHPm has to beat. |
| Include saturation guidance. | Users need to know how to identify the knee of the curve before p95/p99 explode. |
| Show multi-replica behavior. | Native KV and persistent workers raise practical questions about horizontal scaling. |

## Final Assessment

I would not summarize this lab as "ePHPm is faster than PHP-FPM." That would erase too much of what happened.

The better summary is:

> ePHPm did not beat PHP-FPM in normal request mode in this lab. It only became compelling after I used source-built worker mode with native ePHPm KV, where it produced a clear latency win at a gentle rate and sustained far more scheduled work in a medium-traffic burst.

If I were giving this directly to the creator of ePHPm, my advice would be:

| Recommendation | Why |
| --- | --- |
| Position ePHPm as a specialized high-performance PHP application runtime, not a generic PHP-FPM replacement. | The strongest result came from worker mode plus native KV, not from drop-in request mode. |
| Make the successful path the default path in the docs. | A user should not have to fail through several weaker configurations before finding worker mode. |
| Treat PHP version support as a product feature. | Production users will hesitate if they fear being stuck behind PHP security or framework releases. |
| Publish a maintained Laravel example that demonstrates the intended architecture. | The project needs a golden path that users can copy, deploy, and benchmark. |
| Provide clear "good fit / bad fit" guidance. | This will prevent disappointment from users whose apps cannot benefit from persistent workers or native services. |

That is a promising result, not a dismissal. ePHPm has a real performance story. The main improvement opportunity is making that story reachable without source patches, runtime detective work, or accidental tests of the wrong mode.

The project does not need to convince everyone to leave PHP-FPM. It needs to show the right users when leaving PHP-FPM is worth it.
