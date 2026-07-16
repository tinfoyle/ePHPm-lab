# WordPress v5: Plugin-Heavy WooCommerce Store

**Run date:** 2026-07-09 (America/New_York)

**ePHPm image:** `ephpm/ephpm:v0.4.0-php8.4`
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
| ePHPm worker + native KV | **Fail** | `?add-to-cart=` returned `200`, then the Store API cart was empty for both users. |

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

**Update (v0.1.2, 2026-07-11).** The Elementor `Element_Column` redeclaration fatal that blocked the `v0.1.1` retest is addressed upstream in `ephpm/wordpress-worker` `v0.1.2` with a targeted `elementor-idempotent-lifecycle.php` mu-plugin (mirrors the WC pattern). This lab's install script now pins `v0.1.2` and copies both worker-compat mu-plugins from vendor into `wp-content/mu-plugins/`, so the v5 worker lane can finally exercise the cart-integrity gate end-to-end. See [the worker investigation](wordpress-worker-investigation.md) for the traced root cause and the acceptance criteria for the pending v0.1.2 retest.

## Reproduce

Use [the v5 fixture](../wordpress-v5/README.md) and [reproduction guide](reproduction.md#wordpress-v5-woocommerce-test). The harness now makes correctness checks a hard k6 threshold, so it will stop before browse load if the cart workflow fails.
