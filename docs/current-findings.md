# PHP-FPM vs ePHPm: Current Findings

Date: 2026-07-07

## Cluster Shape

- LKE cluster: 3 nodes, all Ready.
- Node type: `g6-standard-1`.
- Per-node allocatable resources: about `940m` CPU and `1.34Gi` memory.
- Test namespace: `php-bench`.

## v1 Test Harness

The first harness used a tiny shared PHP script mounted into both runtimes.

- PHP-FPM side: `nginx:1.27-alpine` plus official `php:8.4-fpm-alpine`.
- ePHPm side: `ephpm/ephpm:8.4`.
- Resource envelopes were equal in total:
  - PHP-FPM/nginx total limit: `250m` CPU, `320Mi` memory.
  - ePHPm total limit: `250m` CPU, `320Mi` memory.

Routes:

- `/hello.php`: minimal JSON response.
- `/cpu.php`: deterministic SHA-256 loop.
- `/json.php`: small JSON encode/decode workload.

## Routing Verification

The tests did hit separate runtimes.

- `service/php-fpm-nginx` selected `app=php-fpm-nginx` and routed to `10.2.0.2:8080`.
- `service/ephpm` selected `app=ephpm` and routed to `10.2.1.131:8080`.
- `php-fpm-nginx` returned `server: nginx/1.27.5` and `php_version: 8.4.23`.
- `ephpm` returned `server: ePHPm/0.1.0` and `php_version: 8.4.22`.

Direct Pod IP checks matched the Service checks. ePHPm direct Pod-IP access required `Host: ephpm` because its default trusted-host configuration rejects raw IP hosts with `421 Misdirected Request`.

## v1 Results

Initial polite run:

| Test | Runtime | Requests | Failed | Avg | Median | p95 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `/hello.php` | PHP-FPM + nginx | 1264 | 0 | 1.57ms | 1.42ms | 2.51ms |
| `/hello.php` | ePHPm | 1264 | 0 | 1.41ms | 1.25ms | 2.44ms |
| `/cpu.php` | PHP-FPM + nginx | 1248 | 0 | 3.85ms | 2.75ms | 6.91ms |
| `/cpu.php` | ePHPm | 1249 | 0 | 3.88ms | 3.10ms | 7.34ms |

This run was intentionally gentle and included `sleep(0.2)` in the k6 script, which capped throughput around 16-17 req/s and muted any throughput difference.

Corrected inspect run:

| Fixed 50 req/s | Runtime | HTTP avg | HTTP median | HTTP p95 | App/script avg |
| --- | --- | ---: | ---: | ---: | ---: |
| `/hello.php` | PHP-FPM + nginx | 1.12ms | 1.03ms | 1.55ms | 2.0us |
| `/hello.php` | ePHPm | 1.29ms | 1.09ms | 2.57ms | 2.11us |
| `/cpu.php` | PHP-FPM + nginx | 2.80ms | 2.53ms | 3.98ms | 1.53ms |
| `/cpu.php` | ePHPm | 3.19ms | 2.72ms | 6.74ms | 1.87ms |

The inspect jobs were pinned to the third node, `lke627470-920560-623d1a350000`, so neither runtime had the load generator co-located with it.

## Interpretation

The current evidence does not show ePHPm outperforming PHP-FPM/nginx. In the corrected inspect run, ePHPm was slightly slower on both the trivial route and the small CPU route.

This does not prove ePHPm is worse in general. It only says the tiny v1 workload did not demonstrate an advantage. PHP-FPM/nginx is highly optimized, and the tested routes were too small to resemble a real application.

## Known Caveats

- PHP versions are not perfectly aligned:
  - PHP-FPM image: PHP `8.4.23`.
  - ePHPm response: PHP `8.4.22`.
- PHP builds are not equivalent:
  - PHP-FPM uses non-thread-safe PHP (`Thread Safety: disabled`).
  - ePHPm uses thread-safe/ZTS embedded PHP (`Thread Safety: enabled`).
- OPcache is not equivalent:
  - ePHPm's embedded PHP reports `Opcode Caching: Disabled`.
  - The ePHPm embedded SAPI reports OPcache startup failure: `Opcode Caching is only supported in Apache, FPM, FastCGI, FrankenPHP, LiteSpeed and uWSGI SAPIs`.
  - This may significantly disadvantage ePHPm for autoloaded multi-file PHP workloads like v2.
- Metrics API is not installed, so `kubectl top pods` is unavailable.
- v1 did not measure CPU or memory per request.
- ePHPm's published image ships with a default config that includes additional features such as trusted-host checks, metrics, security settings, file cache, SQLite/KV configuration, and rate limiting.
- v1 is too synthetic: tiny JSON output and one small hash loop.

## v2 Direction and Limits

The second test moved from a tiny script to a small app-shaped PHP workload:

- Front controller.
- Autoloaded classes.
- JSON fixture reads.
- Template rendering.
- API and HTML routes.
- Query filtering/sorting.
- Fixed-rate k6 runs from a neutral node.

This was a useful step, but it was still not a real workload. It did not use Laravel, Composer dependency graphs, service providers, middleware, routing caches, Blade compilation, database access, session/cache access, or ePHPm worker mode.

The goal is not to hammer the shared LKE cluster. The goal is to see whether ePHPm behaves differently when the runtime does realistic PHP application work rather than a tiny echo path. v2 did not reach that bar yet; it only gave us a better synthetic workload.

## v2 Harness

The v2 harness has been created and deployed.

Files:

- `k8s/php-benchmark-v2.yaml`
- `k8s/k6-v2-php-fpm.yaml`
- `k8s/k6-v2-ephpm.yaml`

Runtime placement:

- `php-fpm-nginx-v2` is pinned to `lke627470-920560-5b9e21970000`.
- `ephpm-v2` is pinned to `lke627470-920560-53ea09140000`.
- k6 v2 jobs are pinned to `lke627470-920560-623d1a350000`.

The v2 app is still intentionally small. It is closer to a real PHP application than v1, but should not be described as a real application benchmark:

- Front controller.
- Autoloader.
- Repository class.
- View renderer class.
- JSON fixture read and decode.
- Filtering, sorting, and summary calculations.
- HTML route and JSON API routes.

Routes used by k6:

- `/products?q=waterproof&sort=score`
- `/products?category=electronics&sort=price`
- `/api/products?q=12v&max_price=200`
- `/api/product?id=8`

The v2 app had one smoke-test bug where a route without `sort` emitted a PHP warning before headers. That was fixed before collecting the v2 numbers below.

## v2 Preliminary Results

Fixed-rate run:

- Rate: `40 req/s`.
- Duration: `45s`.
- Load generator node: `lke627470-920560-623d1a350000`.
- Requests per runtime: `1801`.
- Failed requests: `0` for both.

| Runtime | HTTP avg | HTTP median | HTTP p95 | App elapsed avg | App elapsed p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 1.68ms | 1.40ms | 3.62ms | 178.19us | 239.86us |
| ePHPm | 2.00ms | 1.76ms | 3.51ms | 622.88us | 831.86us |

Interpretation:

- ePHPm did not outperform PHP-FPM/nginx in the first v2 run.
- PHP-FPM showed lower measured application time.
- HTTP p95 was nearly tied, with ePHPm slightly better by this one metric and PHP-FPM better on average and median.
- The v2 result is likely affected by OPcache: ePHPm's embedded SAPI reports OPcache disabled, while PHP-FPM can use OPcache under FPM.
- This is still a lightweight synthetic app. The next useful step is a real Laravel workload, preferably with a comparison between PHP-FPM and ePHPm worker mode.

## Re-Read of ePHPm Claims

The repo's strongest performance claims appear to rely on capabilities we have not tested yet:

- Worker mode (`[php] mode = "worker"`), where a framework boots once and serves many requests from a persistent worker.
- Built-in DB connection pooling.
- Built-in KV/cache access through native ePHPm SAPI functions.
- Reducing or eliminating external Redis/MySQL connection overhead.

Our current tests use normal embedded request handling, no worker loop, no framework boot cost, no DB, and no cache/session layer. That makes them valid for the current setup, but not a direct test of the repo's best-case performance pitch.

## Candidate v3 Workload

A stronger v3 should use an existing Laravel application with real framework bootstrap and real application routes. The target should be popular enough to be representative but small enough to run on this 3-node LKE cluster.

Candidate categories:

- Laravel demo app: easiest to containerize and control, but less representative.
- Laravel CRM: heavier real app shape with auth, models, policies, Blade/Vue/Filament-style admin flows, and database-backed pages.
- Laravel ecommerce: heavier catalog/product/cart flows, but may require more setup and seed data.

Current leading candidates:

- Krayin CRM: open-source Laravel CRM with substantial real app structure.
- Bagisto: open-source Laravel ecommerce platform, likely heavier and more setup-intensive.
- Snipe-IT: mature Laravel asset-management app, practical real-world CRUD workload, but may be heavier operationally.

The v3 plan should avoid proving a point by overfitting. It should define a few repeatable routes first, seed stable data, warm caches, then compare:

- PHP-FPM/nginx, normal Laravel request lifecycle.
- ePHPm embedded mode, if it can run the app unchanged.
- ePHPm worker mode, if the app or adapter path is available and stable enough.

The expected ePHPm advantage, if any, should show up most clearly in worker mode on routes with meaningful Laravel bootstrap cost, DB access, and cache/session behavior.

## v3 Krayin CRM Workload

The v3 workload uses Krayin CRM, a real Laravel application, instead of a synthetic PHP script.

Files:

- `k8s/krayin-v3.yaml`
- `k8s/k6-v3-php-fpm.yaml`
- `k8s/k6-v3-ephpm.yaml`

Krayin source:

- Repository: `https://github.com/krayin/laravel-crm`
- Commit: `7d426f901b18f043eb91e425c7bdd3e9cba568ab`
- Local clone: `apps/laravel-crm`

Runtime placement:

- MySQL and k6 jobs: `lke627470-920560-623d1a350000`
- PHP-FPM/nginx: `lke627470-920560-5b9e21970000`
- ePHPm: `lke627470-920560-53ea09140000`

Runtime shape:

- PHP-FPM side uses `nginx:1.27-alpine` plus official `php:8.4-fpm-bookworm`.
- ePHPm side uses `ephpm/ephpm:8.4`.
- MySQL uses `mysql:8.4`.
- Each app pod prepares Krayin in an `emptyDir` via a Composer init container.
- The install job runs migrations and seeders against MySQL, then creates `admin@example.com` / `admin123`.

Database verification after install:

- Tables in `krayin`: `57`.
- Admin users: `1`.
- `core_config` exists.

Traffic shape:

- k6 logs in through `/admin/login`.
- Requests rotate through dashboard, dashboard stats, leads, lead kanban data, contacts, products, users, and quotes.
- Rate target: `8 req/s`.
- Duration: `75s`.
- This is still gentle, but it exercises Laravel routing, middleware, sessions, Blade, service providers, package code, Eloquent/database queries, and JSON controller paths.

## v3 Compatibility Notes

This test exposed practical ePHPm compatibility issues before benchmarking:

- ePHPm's PHP build has `mbstring`, but `mb_split()` is unavailable because mbregex is disabled. Laravel 12 calls `mb_split()` via `Illuminate\Support\Str`, so the app needed a guarded compatibility shim loaded through Composer autoload.
- `ephpm php artisan ...` did not behave like normal PHP CLI for this app. In this run it initially failed because `$_SERVER['PHP_SELF']` was missing, and then appeared to print the Artisan command list instead of reliably running the requested Krayin installer command. The migration/install job was therefore moved to official PHP CLI.
- Krayin's installer calls `migrate:fresh` without `--force`, which Laravel cancels under `APP_ENV=production`. The install job now runs the underlying migration/seeding steps directly with `--force`.
- The initial v3 comparison tested ePHPm in normal serve mode. A later v3b rerun added worker mode and compared all three modes sequentially under the same conditions; those results are recorded in `docs/ephpm-0.4.0-retest.md`.

The compatibility shim is deliberately small and guarded:

- It supplies `$_SERVER['PHP_SELF']` for ePHPm CLI/server paths that do not populate it.
- It defines `mb_split()` only if the function is missing.

## v3 Results

Both runtimes returned successful responses. There were no HTTP failures in either k6 run, but the throughput and latency difference was large.

| Runtime | HTTP requests | Iterations | Dropped iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 596 | 594 | 7 | 639.82ms | 662.61ms | 1.36s | 1.90s |
| ePHPm | 114 | 112 | 489 | 11.06s | 11.25s | 17.50s | 18.02s |

Interpretation:

- PHP-FPM/nginx sustained the gentle target almost completely.
- ePHPm remained correct, but did not sustain the target rate. k6 reached `16` active VUs, warned about insufficient VUs, and dropped most scheduled iterations.
- This is the first truly app-shaped result, and it is unfavorable to ePHPm in normal serve mode.
- The result should not be generalized to ePHPm worker mode. The later v3b three-way rerun showed worker mode completing slightly more work with lower average latency, while PHP-FPM retained the best p95/p99.

## v4 Straight Laravel + Cache Workload

The v4 workload moved away from Krayin and into a purpose-built Laravel app so we could isolate the shape we wanted:

- Official Docker Hub PHP-FPM image plus nginx.
- ePHPm `8.4` in normal server mode.
- A real Laravel 12 application generated at pod startup.
- SQLite-backed local data reads for the application routes.
- Cache-heavy endpoints.
- PHP-FPM using Redis through Predis over TCP.
- ePHPm using its native SAPI KV functions (`ephpm_kv_get`, `ephpm_kv_set`, `ephpm_kv_expire`, `ephpm_kv_del`, `ephpm_kv_incr`) instead of going through Predis/RESP.

Files:

- `k8s/laravel-v4.yaml`
- `k8s/k6-v4-php-fpm.yaml`
- `k8s/k6-v4-ephpm.yaml`

Traffic shape:

- Rate target: `20 iterations/s`.
- Duration: `75s`.
- Maximum VUs: `40`.
- Route mix:
  - `20%` `/api/bootstrap`
  - `20%` `/dashboard`
  - `40%` `/api/cache-summary`
  - `20%` `/api/counter`

The first v4 attempt used Predis against ePHPm's Redis-compatible RESP listener. That was not a good path: the ePHPm pod was OOMKilled and the k6 run showed high failures and severe dropped iterations. After re-reading the ePHPm docs, we changed the Laravel route helpers to use ePHPm's native KV SAPI functions for the ePHPm deployment. The ePHPm logs then confirmed:

- `KV store wired to PHP native functions`
- `KV store RESP server listening`

The native-KV run avoided the OOM/restart behavior and returned all successful responses, but it still did not keep up with PHP-FPM plus Redis.

| Runtime | Cache path | HTTP requests | Iterations | Dropped iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 0 | 11ms | 8.61ms | 19.66ms | 45.09ms |
| ePHPm | Native ePHPm KV SAPI | 356 | 345 | 1156 | 8.66s | 8.58s | 12.04s | 15.12s |

Per-route latency:

| Runtime | bootstrap p95 | dashboard p95 | cache-summary p95 | counter p95 |
| --- | ---: | ---: | ---: | ---: |
| PHP-FPM + nginx | 10.92ms | 11.88ms | 25.77ms | 26.02ms |
| ePHPm | 15.10s | 11.08s | 9.42s | 7.37s |

Interpretation:

- This v4 test did stack more cards in ePHPm's favor than v3 by using native ePHPm KV instead of external Redis.
- Native ePHPm KV materially improved stability compared with the initial Predis/RESP attempt: no HTTP failures and no ePHPm pod restarts in the final run.
- PHP-FPM plus Redis still dominated the benchmark. It sustained the full target rate with low millisecond latency.
- ePHPm remained correct, but saturated almost immediately, hit the `40` VU ceiling, and dropped most scheduled iterations.
- This still does not test ePHPm's Laravel Octane/worker-mode story. The ePHPm docs indicate worker mode exists, but this run stayed on normal Laravel request handling because the exact Laravel worker package/entrypoint was not established during this pass.

Current factual narrative at the end of the initial v3/v4 pass:

- Our simple synthetic tests did not show a meaningful ePHPm advantage.
- Our real Krayin workload strongly favored PHP-FPM/nginx.
- Our straight Laravel plus cache workload, even with ePHPm native KV, still strongly favored PHP-FPM/nginx plus Redis.
- The remaining question at that point was ePHPm worker mode with a Laravel-compatible persistent worker, ideally combined with DB pooling and native KV. That question was answered for Krayin in the later v3b three-way rerun: worker mode was promising, but it did not win every latency percentile.

## v4 Worker-Mode Attempt

We attempted to add the missing worker-mode comparison after re-reading the ePHPm Laravel Octane guide.

The documented worker-mode setup is:

- Install `laravel/octane`.
- Install `ephpm/octane-driver` and its `ephpm/worker` dependency from GitHub repositories.
- Configure ePHPm with `[php] mode = "worker"`.
- Set `document_root` to the Laravel project root, not `public/`, so `vendor/bin/ephpm-octane-worker` is under the document root.
- Set `worker_script = "vendor/bin/ephpm-octane-worker"`.
- Set `EPHPM_APP_BASE=/var/www/html`.
- Start ePHPm itself; do not run `php artisan octane:start`.

Files added or changed for this attempt:

- `k8s/laravel-v4.yaml`
- `k8s/k6-v4-ephpm-worker.yaml`

Compatibility fixes needed just to install the worker packages:

- The current Laravel installer floated to Laravel 13, but `ephpm/octane-driver` `v0.1.0` declares Laravel framework compatibility only through Laravel 12. The manifest now pins `laravel/laravel:^12.0`.
- Composer tried to clone `git@github.com:ephpm/php-worker.git`, which failed in the pod because there is no SSH credential/host setup. The manifest now resolves `ephpm/worker` and `ephpm/octane-driver` from explicit GitHub tag ZIP archives.

Result:

- Composer installation succeeded after the fixes.
- The worker pod started ePHPm and logged:
  - `starting ePHPm`
  - `PHP runtime initialized (libphp linked)`
  - `KV store wired to PHP native functions`
  - `HTTP listening`
- The pod did not become ready. Kubernetes readiness probes for `/api/bootstrap` returned HTTP `404`.
- Checking the published Docker image showed both `ephpm/ephpm:8.4` and `ephpm/ephpm:latest` report `ephpm 0.2.0`.
- The ePHPm Laravel Octane guide says persistent worker mode ships in ePHPm `3.0`.

Interpretation:

- We could not produce a valid worker-mode benchmark with the currently published `ephpm/ephpm` Docker image.
- This is not a performance result for worker mode. It is a compatibility/runtime-availability result.
- The documented Laravel Octane path appears to require a newer ePHPm runtime than the public Docker image currently provides.
- The worker-mode hypothesis remains untested until we have an ePHPm image or locally built binary that actually includes the documented ePHPm 3.0 worker runtime.

## v4 Worker Mode From Source

We then built ePHPm from source so we could test the documented worker runtime instead of the public Docker Hub image.

This is the first clear victory for ePHPm in our lab.

Source/image details:

- Repo: `https://github.com/ephpm/ephpm`
- Commit: `469c51e` (`fix: review follow-ups (ratelimit TTL, ext ini-injection, jwt float-exp, docs) (#127)`)
- Local image: `lke-lab/ephpm:source-469c51e`
- Temporary pull image used by LKE: an ephemeral `ttl.sh` image, now expired
- Runtime smoke test: `ephpm source-469c51e`

Source-build fixes needed:

- The Dockerfile example defaulted toward a newer PHP SDK; for PHP 8.4 we used the repo-pinned SDK `8.4.22`.
- Rust stable was required because current dependencies need a newer compiler than Rust 1.85.
- The container build needed GNU `bfd` linking instead of Rust's self-contained `lld` path.
- PHP's static `dns.o` referenced legacy glibc resolver symbols (`__dn_expand`, `__dn_skipname`, `__res_nsearch`). We added a small local compatibility shim forwarding those names to modern public resolver APIs.
- The local Dockerfile/build-script patches are in `apps/ephpm/docker/Dockerfile`, `apps/ephpm/crates/ephpm/build.rs`, `apps/ephpm/crates/ephpm-php/build.rs`, and `apps/ephpm/crates/ephpm-php/resolver_compat.c`.

Kubernetes/Laravel worker fixes needed:

- The temporary image pulled successfully in LKE.
- The first source-built worker pod started but failed Laravel worker boot because the package repository metadata over-escaped PSR-4 namespaces, producing Composer prefixes like `Ephpm\\\\Octane\\\\`.
- We corrected the package metadata in `k8s/laravel-v4.yaml` to generate normal prefixes like `Ephpm\\Octane\\`.
- We also left a narrow compatibility `require_once` for `vendor/ephpm/worker/src/Runtime.php` in the generated worker script.
- After those fixes, `deployment/laravel-v4-ephpm-worker` rolled out successfully.

Worker-mode k6 comparison:

| Runtime | Cache path | HTTP requests | Iterations | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | Failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | Native ePHPm KV SAPI | 1512 | 1501 | 4.71ms | 3.90ms | 10.16ms | 16.66ms | 0 |
| PHP-FPM + nginx | Redis via Predis/TCP | 1512 | 1501 | 11.33ms | 9.02ms | 19.75ms | 44.13ms | 0 |

Per-route latency:

| Runtime | bootstrap avg/p95 | dashboard avg/p95 | cache-summary avg/p95 | counter avg/p95 |
| --- | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 5.36ms / 12.44ms | 6.13ms / 13.80ms | 3.87ms / 6.83ms | 4.22ms / 9.73ms |
| PHP-FPM + nginx | 8.54ms / 10.82ms | 8.98ms / 11.40ms | 10.34ms / 17.69ms | 18.97ms / 43.95ms |

Interpretation:

- This is the first result that supports ePHPm's performance story in our lab.
- The advantage appears only after moving to the source-built worker runtime and using ePHPm native KV.
- The biggest win is the cache/counter path, where avoiding PHP-FPM process handoff plus Redis/Predis round trips materially reduces latency.
- This does not invalidate the earlier findings: public `ephpm/ephpm:8.4` normal mode and public-image worker attempts did not beat PHP-FPM in our tests.
- The factual narrative is now more precise: ePHPm worker mode can be faster for this Laravel/KV workload, but the currently published Docker image was not sufficient to test that path, and source-build/runtime integration work was required.

Extra detail for the first victory:

- The test was a latency comparison at a gentle capped rate, not a saturation ceiling test.
- Both jobs used the same k6 script, target rate, route mix, duration, and load-generator placement.
- Both jobs completed `1501` iterations with `0` interrupted iterations and `0` HTTP failures.
- Each job made `1512` HTTP requests: `1501` measured iterations plus `11` setup/warmup requests.
- k6 reported `vus_max=12`, but the active VU count stayed around `0-1` at this target rate. That means neither runtime was pushed to its concurrency ceiling in this run.
- The Kubernetes metrics API was not available, so `kubectl top pods` / `kubectl top nodes` could not provide CPU or memory snapshots.

Relative latency deltas:

| Metric | ePHPm worker | PHP-FPM | ePHPm delta |
| --- | ---: | ---: | ---: |
| HTTP avg | 4.71ms | 11.33ms | 2.41x faster / 58.4% lower |
| HTTP median | 3.90ms | 9.02ms | 2.31x faster / 56.8% lower |
| HTTP p90 | 6.48ms | 14.76ms | 2.28x faster / 56.1% lower |
| HTTP p95 | 10.16ms | 19.75ms | 1.94x faster / 48.6% lower |
| HTTP p99 | 16.66ms | 44.13ms | 2.65x faster / 62.2% lower |
| HTTP max | 38.18ms | 160.45ms | 4.20x faster / 76.2% lower |
| Iteration avg | 25.29ms | 32.15ms | 1.27x faster / 21.3% lower |
| Iteration p99 | 38.40ms | 68.05ms | 1.77x faster / 43.6% lower |

Endpoint-specific deltas:

| Endpoint metric | ePHPm worker | PHP-FPM | ePHPm delta |
| --- | ---: | ---: | ---: |
| `/api/bootstrap` avg | 5.36ms | 8.54ms | 1.59x faster / 37.3% lower |
| `/api/bootstrap` p95 | 12.44ms | 10.82ms | 15.0% slower |
| `/dashboard` avg | 6.13ms | 8.98ms | 1.46x faster / 31.7% lower |
| `/dashboard` p95 | 13.80ms | 11.40ms | 21.0% slower |
| `/api/cache-summary` avg | 3.87ms | 10.34ms | 2.67x faster / 62.6% lower |
| `/api/cache-summary` p95 | 6.83ms | 17.69ms | 2.59x faster / 61.4% lower |
| `/api/counter` avg | 4.22ms | 18.97ms | 4.50x faster / 77.8% lower |
| `/api/counter` p95 | 9.73ms | 43.95ms | 4.52x faster / 77.9% lower |
| `/api/counter` p99 | 15.40ms | 130.96ms | 8.51x faster / 88.2% lower |

What the win seems to mean:

- ePHPm worker mode did not merely improve averages; it crushed the FPM tail on the cache/counter path.
- PHP-FPM was competitive on framework-heavy non-cache routes at p95, especially `/api/bootstrap` and `/dashboard`.
- ePHPm's clearest advantage in this test is exactly where the architecture should help: persistent Laravel worker plus in-process/native ePHPm KV instead of per-request FPM handoff plus Redis over Predis/TCP.
- A fair next detail pass would be a rate ladder, for example `20`, `40`, `60`, and `80` iterations/s with short runs, to find where each runtime starts dropping iterations or growing p95/p99 latency.

## v4 Rate-8 Medium Traffic Quick Test

After the first worker-mode win, we ran a quick "crank it to 8" test.

Definition of rate-8:

- Previous gentle v4 rate: `20` iterations/s.
- Rate-8 target: `160` iterations/s.
- Duration: `45s`.
- Scenario: k6 `constant-arrival-rate`.
- Requested workload: about `7200` scheduled measured iterations, plus `11` setup/warmup requests.
- k6 placement: same load-generator node for both jobs.
- Route mix: same v4 Laravel/KV mix:
  - `20%` `/api/bootstrap`
  - `20%` `/dashboard`
  - `40%` `/api/cache-summary`
  - `20%` `/api/counter`

Fairness note:

- The first rate-8 attempt accidentally applied both ePHPm and PHP-FPM k6 jobs at the same time.
- That concurrent run was treated only as a shakedown and was discarded for the side-by-side comparison.
- The recorded comparison below comes from sequential runs: ePHPm worker first, then PHP-FPM + nginx + Redis.

Manifests:

- Shared script/config: `k8s/k6-v4-rate8.yaml`
- ePHPm-only job: `k8s/k6-v4-rate8-ephpm-worker.yaml`
- PHP-FPM-only job: `k8s/k6-v4-rate8-php-fpm.yaml`

Headline result:

| Runtime | Target rate | Completed iterations | Iteration rate | Dropped iterations | HTTP requests | HTTP avg | HTTP median | HTTP p95 | HTTP p99 | HTTP max | Failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 160/s | 7091 | 156.53/s | 110 | 7102 | 141.82ms | 3.83ms | 819.08ms | 1.23s | 1.37s | 0 |
| PHP-FPM + nginx + Redis | 160/s | 4744 | 101.79/s | 2457 | 4755 | 1.44s | 1.49s | 1.72s | 2.50s | 2.57s | 0 |

Completion and drop-rate view:

| Runtime | Approx scheduled iterations completed | Scheduled iterations dropped |
| --- | ---: | ---: |
| ePHPm source worker mode | 98.5% | 1.5% |
| PHP-FPM + nginx + Redis | 65.9% | 34.1% |

Relative deltas at rate-8:

| Metric | ePHPm worker | PHP-FPM | ePHPm delta |
| --- | ---: | ---: | ---: |
| Completed iteration rate | 156.53/s | 101.79/s | 1.54x higher |
| Dropped iterations | 110 | 2457 | 95.5% fewer drops |
| HTTP avg | 141.82ms | 1.44s | about 90% lower |
| HTTP median | 3.83ms | 1.49s | about 99.7% lower |
| HTTP p95 | 819.08ms | 1.72s | about 52% lower |
| HTTP p99 | 1.23s | 2.50s | about 51% lower |
| HTTP max | 1.37s | 2.57s | about 47% lower |

Endpoint tails:

| Runtime | bootstrap p95/p99 | dashboard p95/p99 | cache-summary p95/p99 | counter p95/p99 |
| --- | ---: | ---: | ---: | ---: |
| ePHPm source worker mode | 852.95ms / 1.28s | 424.80ms / 782.14ms | 836.26ms / 1.30s | 884.70ms / 982.47ms |
| PHP-FPM + nginx + Redis | 1.64s / 1.83s | 1.77s / 2.53s | 1.73s / 2.50s | 1.92s / 2.52s |

Interpretation:

- At rate-8, PHP-FPM did not fail requests, but it could not sustain the requested arrival rate. k6 dropped `2457` scheduled iterations, and effective measured throughput fell to about `102` iterations/s.
- ePHPm also showed pressure. It dropped `110` scheduled iterations and had very ugly p95/p99 latency compared with the gentle `20` iterations/s run.
- Even under that pressure, ePHPm mostly kept up with the requested rate, completing about `98.5%` of scheduled measured iterations.
- The shape of the result matters: ePHPm's median stayed tiny at `3.83ms`, while PHP-FPM's median moved to `1.49s`. That suggests PHP-FPM was spending most of the test backed up, while ePHPm had intermittent latency spikes but continued clearing most requests quickly.
- This is the strongest medium-traffic evidence so far for ePHPm worker mode plus native KV in this lab.
- It is still a quick test, not a production capacity claim. We would need repeated runs, CPU/memory metrics, and a rate ladder around the breaking point to make a more formal statement.
