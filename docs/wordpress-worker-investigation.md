# WordPress Worker Follow-Up: WooCommerce Cart Lifecycle

**Status:** reproducible functional compatibility bug; not fixed in this lab.

**Affected shape:** ePHPm WordPress persistent worker plus WooCommerce guest cart.

**Not affected in this lab:** PHP-FPM/nginx and ePHPm normal request mode.

This is the follow-up to the failed WordPress v5 worker cart gate. It is a functional investigation, not a throughput result. The worker lane must remain excluded from performance comparison until this flow passes.

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
