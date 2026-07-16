# WordPress v5: Plugin-Heavy WooCommerce Store

**Run date:** 2026-07-09 (America/New_York)

**Original ePHPm image:** `ephpm/ephpm:v0.4.0-php8.4`
**Baseline image:** `php:8.4-fpm-bookworm` behind `nginx:1.27-alpine`

## Question

Can ePHPm be competitive with a conventional PHP-FPM WordPress deployment when the workload is a real WooCommerce-style storefront rather than an empty WordPress install?

This is still a lab. It is intentionally richer than a fresh installation, but it does not claim to represent every production store.

## Fixture and Fairness

The three lanes used the same MySQL 8.4 database and the same seeded WordPress 7.0 fixture:

| Content | Count |
| --- | ---: |
| Simple products | 1,000 |
| Variable products | 200 |
| Product variations | 800 |
| Product reviews | 2,000 |
| Blog posts | 300 |
| Completed orders | 200 |

The active public plugins were WooCommerce, Elementor, OceanWP, Ocean Extra, Yoast SEO, Advanced Custom Fields, Contact Form 7, and Redis Object Cache. The fixture records the resolved plugin versions in the `ephpm_lab_v5_plugin_versions` WordPress option at installation time.

| Lane | Web/runtime shape | Object cache |
| --- | --- | --- |
| PHP-FPM | nginx -> official PHP 8.4 FPM | `phpredis` -> Redis 7.4 |
| ePHPm request | Service -> ePHPm request mode | `ephpm/cache-wordpress` -> native KV |
| ePHPm worker | Service -> ePHPm WordPress worker, two workers | `ephpm/cache-wordpress` -> native KV |

The cache topology is intentionally part of the comparison. This is a deployment-shape test, not a claim that the two cache implementations are interchangeable.

All application lanes were run one at a time on the same three-node small Linode LKE cluster. Metrics Server was not installed, so this run has no trustworthy per-pod CPU or memory series.

## Correctness Gate

Before measuring browse traffic, k6 used two independent virtual users to add different products to their carts, then queried WooCommerce's Store API. A passing run needed a `200` response, the caller's own item, and no item from the other caller. This is a small but meaningful test of session and request-state behavior.

| Lane | Cart gate | Observation |
| --- | --- | --- |
| PHP-FPM + Redis | Pass | 14/14 checks; zero HTTP failures. |
| ePHPm request + native KV | Pass | 14/14 checks; zero HTTP failures. |
| ePHPm worker + native KV (`v0.4.0`) | **Fail** | `?add-to-cart=` returned `200`, then the Store API cart was empty for both users. |
| ePHPm worker + native KV (`v0.5.0`, adapter `v0.1.2`) | **Pass** | 14/14 checks; zero HTTP failures; each user saw only its own item. |

Follow-up tracing identified the immediate `v0.1.0` cause: WooCommerce registers its `add_to_cart_action()` handler on WordPress's `wp_loaded` action, but the persistent worker adapter booted WordPress once and did not replay `wp_loaded` for each request. The `?add-to-cart=` request therefore rendered a normal `200` storefront page instead of performing the add-to-cart redirect or setting the WooCommerce session cookie. ePHPm's `wordpress-worker` `v0.1.1` added lifecycle replay, but the v5 retest then hit a separate Elementor `Element_Column` redeclaration fatal before the cart gate could run. See [the worker investigation](wordpress-worker-investigation.md). I did not run the worker browse benchmark after either failure. Its short response times would not make it a valid WooCommerce result while ordinary cart behavior is broken.

## Browse Load

The valid lanes used the same k6 constant-arrival-rate profile: `8 iterations/s` for `120s`, cycling through a product page, catalog page, and product search. Higher completed iterations are better; lower latency is better.

| Metric | PHP-FPM + nginx + Redis | ePHPm request + native KV |
| --- | ---: | ---: |
| Completed iterations | 504 | 522 |
| Dropped iterations | 457 | 439 |
| Effective iteration rate | 4.01/s | 4.26/s |
| HTTP failures | 0 | 0 |
| HTTP average | 5.49s | 5.21s |
| HTTP median | 5.69s | 5.22s |
| HTTP p90 | 6.47s | 6.47s |
| HTTP p95 | **6.69s** | 6.81s |
| HTTP max | **7.28s** | 8.40s |

Per-route averages were similarly close: PHP-FPM measured 6.09s for product, 5.20s for catalog, and 5.85s for search; ePHPm request mode measured 5.49s, 5.11s, and 5.38s respectively.

## Reading the Result

This is not a universal runtime victory. In this constrained, cache-backed store fixture, ePHPm request mode had a modest advantage in completed work, average latency, and median latency. PHP-FPM held the better p95 and maximum response time. The difference is small enough that it needs a longer run, node-level metrics, and more worker/process tuning before it should influence a production choice.

The worker finding is equally important: ePHPm's WordPress worker architecture is promising in principle, but `v0.4.0` did not pass this WooCommerce session workflow. Until that behavior is fixed and retested, PHP-FPM is the validated choice for this worker-style storefront path.

**Update (v0.5.0 / adapter v0.1.2, 2026-07-16).** The Elementor `Element_Column` redeclaration fatal and WooCommerce cart lifecycle failure are resolved for this fixture. The worker lane passed the cart gate end-to-end with 14/14 checks and zero HTTP failures. The first worker browse run used the same `8 iterations/s` for `120s` profile, but is not comparable to the valid normal-request runs: it completed `341` iterations, dropped `618`, returned `12` non-200 responses (3.79% HTTP failure rate), and recorded 7.78s average / 27.49s p95 latency. Its `wordpress_v5_ok` rate was 96.48%, below the 99% threshold. The deployment had two explicit workers on the same small-node cluster, so this establishes a remaining worker-capacity or stability problem, not a WordPress functional regression. It needs worker-count and resource tuning, response-code tracing, and a clean rerun before being charted against PHP-FPM or ePHPm request mode. See [the worker investigation](wordpress-worker-investigation.md).

**Capacity rerun (2026-07-16).** Metrics Server confirmed the original worker pod was CPU-bound near its `900m` limit. Moving the lane to a `g6-standard-2` node (2 vCPU), raising the pod to `1800m` CPU / `2Gi` memory, and using four workers made the same 8/s profile functionally clean: `524` completed iterations, `437` dropped, zero HTTP failures, 100% application checks, 3.91s average latency, and 17.38s p95. The sampled pod used about 1.35 cores and its node about 68% CPU. This is strong evidence that the earlier failure was materially CPU-capacity-driven, but the run still did not sustain the requested 8/s and is not yet a final PHP-FPM comparison.

## Reproduce

Use [the v5 fixture](../wordpress-v5/README.md) and [reproduction guide](reproduction.md#wordpress-v5-woocommerce-test). The harness now makes correctness checks a hard k6 threshold, so it will stop before browse load if the cart workflow fails.
