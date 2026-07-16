# WordPress Worker Follow-Up: WooCommerce Cart Lifecycle

**Status:** original functional compatibility bugs fixed in the v5 fixture; browse-load reliability remains under investigation.

**Affected shape:** ePHPm WordPress persistent worker plus WooCommerce guest cart.

**Not affected in this lab:** PHP-FPM/nginx and ePHPm normal request mode.

This is the follow-up to the failed WordPress v5 worker cart gate. The original WooCommerce lifecycle and Elementor compatibility failures are resolved in the v0.5.0/v0.1.2 retest. The worker lane remains excluded from performance comparison until it can also sustain the v5 browse profile within its reliability thresholds.

## Exact Environment

| Component | Value |
| --- | --- |
| ePHPm image | `ephpm/ephpm:v0.4.0-php8.4` |
| ePHPm mode | `worker` |
| Worker adapter | `ephpm/wordpress-worker` `v0.1.0` |
| Worker configuration | `worker_populate_superglobals = true`, `worker_count = 2`, `worker_max_requests = 250` |
| WordPress | 7.0 |
| WooCommerce | 10.9.4 |
| Theme/plugins | OceanWP, Elementor, Ocean Extra, Yoast, ACF, Contact Form 7, Redis Object Cache |
| WordPress object cache | `ephpm/cache-wordpress` native-KV drop-in |

The fixture, worker configuration, and cart gate are public in this repository: [worker config](../wordpress-v5/scripts/ephpm-worker-start.sh), [fixture setup](../wordpress-v5/scripts/prepare-wordpress.sh), and [k6 gate](../wordpress-v5/k6/cart-integrity.js).

## Minimal Reproduction

Use a new cookie jar and a known simple-product ID.

1. `GET /?add-to-cart=<product-id>` with `Host: wordpress-v5.local`, without following redirects.
2. Capture the status, `Location`, and `Set-Cookie` headers.
3. `GET /wp-json/wc/store/v1/cart` with the same jar.

Expected WooCommerce behavior:

- The add request invokes `WC_Form_Handler::add_to_cart_action()`.
- It redirects after a successful add and emits a `wp_woocommerce_session_*` cookie.
- The Store API sees the selected product in the caller's cart.

Observed worker behavior:

| Observation | Result |
| --- | --- |
| Add request status | `200` |
| Add response | Normal rendered OceanWP storefront page |
| `Location` header | Absent |
| `Set-Cookie` header | Absent |
| k6 cookie jar after add | Empty |
| Store API cart | Empty `items` array |
| PHP-FPM and ePHPm request mode | Both pass the identical two-user gate |

The two-user gate additionally verifies that each shopper sees only their own item. It is not relying on persistence between k6 iterations: each virtual user adds an item and reads its cart using the same jar within that iteration.

## Root-Cause Trace

WooCommerce registers its request handlers during plugin bootstrap, including `add_to_cart_action()` on the **per-request** `wp_loaded` lifecycle action:

```php
add_action( 'wp_loaded', array( __CLASS__, 'add_to_cart_action' ), 20 );
```

Source: [WooCommerce 10.9.4 `WC_Form_Handler::init()`](https://github.com/woocommerce/woocommerce/blob/10.9.4/plugins/woocommerce/includes/class-wc-form-handler.php#L22-L38), [handler guard for `add-to-cart`](https://github.com/woocommerce/woocommerce/blob/10.9.4/plugins/woocommerce/includes/class-wc-form-handler.php#L847-L850).

The adapter boots WordPress once with `require wp-load.php`, then its persistent loop prepares request state and runs `wp()` plus the template loader. That loop does not dispatch `wp_loaded` for each worker iteration:

```php
require $__abs . 'wp-load.php'; // once, before the loop

while (($__env = \Ephpm\Worker\take_request()) !== null) {
    $__target = $__ephpmWorker->beforeRequest($__env);
    wp();
    require ABSPATH . WPINC . '/template-loader.php';
}
```

Source: [ePHPm WordPress worker entrypoint](https://github.com/ephpm/wordpress-worker/blob/v0.1.0/bin/ephpm-wp-worker#L80-L119).

That control flow explains the wire result: the plugin callback was registered during the one-time boot, but its `wp_loaded` event is not fired for the later request. The request reaches the normal front controller and renders the homepage, while the WooCommerce add-to-cart action never runs.

## Evidence That Narrows the Scope

- A worker REST probe received `?ephpm_probe=cart` in `$_GET`, so this is not a blanket query-string parsing failure.
- A temporary `woocommerce_add_to_cart` diagnostic action did not fire during the failing request, confirming the handler is never reached.
- The failure occurs before a WooCommerce session can be established. No `wp_woocommerce_session_*` cookie is emitted, so the following Store API request has no guest-cart identity.
- Worker logs also show repeated `REST_REQUEST already defined` warnings. Those are a separate request-reset concern worth tracking, but are not needed to explain the failed add-to-cart path.

## Why Native PHP Sessions Do Not Fix This

ePHPm native KV-backed PHP sessions are relevant to applications using `session_start()` and `$_SESSION`. WooCommerce guest carts do not use that mechanism: they persist their data in `wp_woocommerce_sessions` and identify the browser with a WooCommerce cookie. Enabling `session.save_handler = ephpm` may be useful for WordPress plugins that use PHP sessions, but cannot make the missing WooCommerce add-to-cart callback run.

## Candidate Fix Direction

This needs an adapter lifecycle decision, not a benchmark-side workaround. The smallest experiment is to dispatch the required WordPress request lifecycle after `beforeRequest()` has rebuilt the request superglobals and before `wp()` routes the request:

```php
$__target = $__ephpmWorker->beforeRequest($__env);
do_action( 'wp_loaded' );
wp();
require ABSPATH . WPINC . '/template-loader.php';
```

The adapter also needs an intentional per-request shutdown phase. WooCommerce attaches session persistence to `shutdown`, so the implementation should audit whether it must dispatch `do_action( 'shutdown' )` once for every completed request, including redirect and exception paths.

Do **not** treat those snippets as a ready patch. Replaying lifecycle hooks can expose plugins that dynamically register hooks or assume process teardown. The adapter should define which WordPress lifecycle actions it replays, their ordering, and how it prevents per-request registrations from accumulating.

## Regression Coverage Required Upstream

Add a real WooCommerce worker E2E test alongside the existing WordPress worker login/REST coverage:

1. Boot WordPress plus WooCommerce in ePHPm worker mode.
2. Create or seed one simple purchasable product.
3. Send `GET /?add-to-cart=<product-id>` without automatically following redirects.
4. Assert a redirect and a `wp_woocommerce_session_*` cookie.
5. Follow the redirect or call `/wp-json/wc/store/v1/cart` with that cookie.
6. Assert the cart contains the selected product.
7. Repeat with a second independent cookie jar and a different product; assert no cart cross-talk.
8. Repeat after enough requests to recycle a worker, proving lifecycle behavior survives worker replacement.

## Acceptance Criteria For a Retest

- The cart gate passes with two independent users and zero HTTP failures.
- The worker returns a real add-to-cart redirect and WooCommerce session cookie.
- Store API cart contents survive the next request and are isolated by cookie jar.
- Existing WordPress login and REST worker tests remain green.
- No unbounded hook growth or duplicate handler execution appears across repeated worker requests.
- Only after those checks pass should the v5 worker browse benchmark be run and compared with PHP-FPM and ePHPm request mode.

## Upstream Fix

`ephpm/wordpress-worker` `v0.1.1` (2026-07-10) addresses this investigation:

- The worker now re-fires `init` and `wp_loaded` for every request (and
  `shutdown` after the response), with boot-time `did_action` counters reset
  so plugins observe php-fpm-identical hook counts from the first request.
  File-level bootstrap (plugin/theme loading) remains one-shot.
- The regression test specified above is implemented in the adapter's `e2e/`
  suite, including the two-user cart-isolation variant: it fails 1/5 against
  `v0.1.0` and passes 5/5 against `v0.1.1` (verified on WordPress 6.7.1 +
  WooCommerce 9.4.3; this lab's WP 7.0 + WC 10.9.4 combination is the
  remaining confirmation).
- One additional finding from implementing the fix: WooCommerce's session
  handler singleton retains boot-time cookie state even with the lifecycle
  actions replayed. The release ships an optional mu-plugin
  (`muplugins/woocommerce-session-per-request.php`) that rebinds it per
  request, documented in the adapter README alongside the new explicit
  lifecycle contract (what fires once vs per request, and the observable
  differences from php-fpm).

The v5 fixture in this repo now pins `ephpm/wordpress-worker:0.1.1` so a
worker-lane rerun exercises the fix deterministically.

## v5 Retest Against `v0.1.1`

**Result: blocked before the cart gate.** The v5 worker deployment was rebuilt after the pin and Composer's lock file confirmed the adapter source as `v0.1.1` (`0331ff6840cfaf64aef0f3b2033676e1bdbfa984`). On the first cart-fixture API request, the worker emitted:

```text
PHP Fatal error: Cannot redeclare class Elementor\Element_Column
.../wp-content/plugins/elementor/includes/elements/column.php:19
```

The cart-fixture endpoint consequently returned an HTTP failure before k6 could select products or exercise `?add-to-cart=`. This is distinct from the original WooCommerce lifecycle failure: the `v0.1.1` lifecycle replay now exposes an Elementor compatibility failure in this plugin-heavy fixture.

No worker browse benchmark was run. This lane remained functionally invalid on the published v5 stack until both the WooCommerce and Elementor paths passed their correctness gates.

## Elementor Fix in `v0.1.2`

`ephpm/wordpress-worker` `v0.1.2` (2026-07-11) addresses the Elementor block with a targeted mu-plugin:

- **Root cause (source-verified):** `Elements_Manager::require_files()` at `includes/managers/elements.php:461-463` uses `require` (not `require_once`) for `column.php`, `section.php`, and `repeater.php`. That method is called from `Elements_Manager::__construct()` (line 58), which is instantiated by `Plugin::init_components()`, which runs from `Plugin::init()` registered on the `init` action at priority 0 (`plugin.php:833`). Under FPM, `init` fires once per process — correct. Under the worker's per-request replay, request N ≥ 2 re-runs `require` and the classes redeclare.
- **Fix shape:** the adapter now ships `muplugins/elementor-idempotent-lifecycle.php` mirroring the WooCommerce mu-plugin pattern. At `wp_loaded` `PHP_INT_MAX` (once, boot-time) it calls `remove_action('init', [\Elementor\Plugin::instance(), 'init'], 0)` — strips exactly the callback that triggers the redeclaring chain. All other Elementor hooks (REST, admin, editor, widget-render) remain registered.
- **Reproduction verified** upstream against Elementor 4.1.4 + WP 7.0 + `ephpm/ephpm:v0.4.2-php8.4`: without the mu-plugin, every request kills a worker (each is recycled and the next request lands on a fresh boot); with it, one worker survives 5+ consecutive requests with zero `Cannot redeclare` fatals. See [PR #4](https://github.com/ephpm/wordpress-worker/pull/4) for the traced source path and worker logs.

This lab's `wordpress-v5/scripts/install-wordpress-worker.sh` pins `ephpm/wordpress-worker:0.1.2` and, after Composer has populated `vendor/`, copies both mu-plugins (`woocommerce-session-per-request.php`, `elementor-idempotent-lifecycle.php`) into `wp-content/mu-plugins/`. Both are required — the `v0.1.1` retest didn't actually install either.

## Acceptance Criteria For a v0.1.2 Retest

Re-run the v5 worker lane with `v0.1.2` pinned and the mu-plugins dropped in. Expected outcomes:
- No `Cannot redeclare` fatal in the worker log across the cart-integrity gate iterations.
- The two-user cart gate (`cart-integrity.js`) passes with `200`, correct item echoes, and zero cross-talk between the two virtual users.
- Store API cart contents survive the next request and are isolated by cookie jar.
- Only after those pass should the v5 worker browse benchmark be run and compared with PHP-FPM and ePHPm request mode.

## v0.5.0 / v0.1.2 Retest (2026-07-16)

The retest used `ephpm/ephpm:v0.5.0-php8.4` and Composer-resolved `ephpm/wordpress-worker:v0.1.2` (`7b08bbe50d1ac4235a9dfdd98c9cea537a618a02`). The lab deployment contains both required adapter mu-plugins. An initial lab integration mistake had copied them from `vendor/` in an earlier init container, before Composer had installed the package; the copy now happens in `install-wordpress-worker.sh` after `composer require` completes.

### Correctness Result

The unchanged two-user cart gate passed: 14/14 checks and zero HTTP failures. Both workers booted cleanly, and there was no Elementor redeclaration fatal. Each virtual user added a distinct product and saw only its own cart item through the next Store API request.

This resolves the workflow blocker that invalidated the earlier worker results.

### Browse Result

The unchanged browse profile (`8 iterations/s` for `120s`) did not meet the harness reliability thresholds on the two-worker, small-LKE-node deployment:

| Metric | Result |
| --- | ---: |
| Completed iterations | 341 |
| Dropped iterations | 618 |
| HTTP failures | 3.79% (12 non-200 responses) |
| `wordpress_v5_ok` | 96.48% |
| HTTP average | 7.78s |
| HTTP median | 2.46s |
| HTTP p90 | 24.45s |
| HTTP p95 | 27.49s |

The k6 job correctly failed because `http_req_failed < 1%` and `wordpress_v5_ok > 99%` were crossed. This is not evidence that the original WordPress worker functional bug remains: the cart gate is green. It is evidence that the present worker capacity or request handling is not reliable at this arrival rate. The next investigation should capture the failing response status/body, repeat at multiple worker counts and lower rates, and pair results with CPU and memory metrics before making a performance comparison.

## Capacity Rerun on `g6-standard-2` (2026-07-16)

Metrics Server was installed and the worker was moved from a small `g6-standard-1` node to a fresh `g6-standard-2` node. The rerun used four workers, a pod limit of `1800m` CPU and `2Gi` memory, and the unchanged 8/s for 120s browse profile.

| Metric | Small node / 2 workers | `g6-standard-2` / 4 workers |
| --- | ---: | ---: |
| Completed iterations | 341 | 524 |
| Dropped iterations | 618 | 437 |
| HTTP failures | 3.79% | 0.00% |
| Application checks | 96.48% | 100.00% |
| HTTP average | 7.78s | 3.91s |
| HTTP p95 | 27.49s | 17.38s |

During the larger-node run the worker used about 1.35 CPU cores and the node sampled at about 68% CPU. The original run repeatedly approached the `900m` pod CPU limit and saturated its node. The scale-up therefore resolves the browse reliability failure and strongly implicates CPU capacity, while the remaining dropped iterations show that this exact four-worker deployment has not yet reached the full 8/s target.
