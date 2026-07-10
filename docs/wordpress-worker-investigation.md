# WordPress Worker Follow-Up: WooCommerce Cart Lifecycle

This follow-up explains the failed WordPress v5 ePHPm worker cart gate. It is a functional investigation, not a throughput result.

## Reproduction

The affected lane used `ephpm/ephpm:v0.4.0-php8.4` in worker mode with `worker_populate_superglobals = true`, two workers, the `ephpm/wordpress-worker` `v0.1.0` adapter, WordPress 7.0, and WooCommerce 10.9.4.

1. Request `/?add-to-cart=<simple-product-id>` with a new cookie jar.
2. Read `/wp-json/wc/store/v1/cart` with that same jar.
3. Expect a WooCommerce redirect/cookie on the first request and the added item on the second.

PHP-FPM and ePHPm request mode pass this flow. Worker mode returned a normal `200` storefront page, sent no WooCommerce session cookie, and returned an empty Store API cart.

## Cause

WooCommerce registers `WC_Form_Handler::add_to_cart_action()` on WordPress's `wp_loaded` action. The ePHPm adapter bootstraps WordPress once, then each worker iteration runs the front controller through `wp()` and the template loader. It does not replay `wp_loaded` for each request. As a result, the normal WooCommerce add-to-cart handler never executes in the resident worker.

This explains the result more directly than a cache or k6 theory:

- The request query string itself was present in `$_GET` on a worker REST probe.
- The add-to-cart request rendered the normal storefront, rather than redirecting.
- `woocommerce_add_to_cart` did not fire in a temporary diagnostic hook.
- No `wp_woocommerce_session_*` cookie reached the client, so the subsequent Store API request had no cart identity.

## PHP Sessions and Native KV

ePHPm's native PHP session handler is a useful feature for applications that use `session_start()` and `$_SESSION`. It does not repair this particular path: WooCommerce stores guest carts in its own `wp_woocommerce_sessions` table and identifies them with a WooCommerce cookie, rather than using PHP sessions.

## Upstream Test To Add

The worker adapter needs an end-to-end WooCommerce regression test, not only WordPress login and REST coverage:

1. Boot WordPress plus WooCommerce in worker mode.
2. Send `GET /?add-to-cart=<simple-product-id>` without following redirects.
3. Assert the expected redirect and `wp_woocommerce_session_*` cookie.
4. Send the Store API cart request with that cookie.
5. Assert that the cart contains the selected product.

The implementation question is how to reproduce the WordPress lifecycle events required by resident plugins without rerunning one-time bootstrap hooks. The adapter should make that lifecycle contract explicit and validate it against WooCommerce before worker mode is presented as a general WordPress deployment shape.
