# WordPress v5 Fixture

This directory contains the account-free fixture for the v5 WordPress benchmark. It uses only public WordPress.org packages and test-only local data.

## Application Stack

| Component | Version |
| --- | --- |
| WordPress | 7.0 |
| WooCommerce | Public WordPress.org release, recorded at install time |
| Elementor | Public WordPress.org release, recorded at install time |
| OceanWP | 4.2.1 |
| Ocean Extra | Public WordPress.org release, recorded at install time |
| Yoast SEO | Public WordPress.org release, recorded at install time |
| Advanced Custom Fields | Public WordPress.org release, recorded at install time |
| Contact Form 7 | Public WordPress.org release, recorded at install time |
| Redis Object Cache | Resolved at install and written to the fixture metadata |

The primary comparison is PHP-FPM/nginx plus `phpredis` and Redis against ePHPm request mode and ePHPm WordPress worker mode with `ephpm/cache-wordpress` and native KV. The cache backend is intentionally part of the deployment shape, not hidden as a runtime-only claim.

The init script logs and stores the resolved active-plugin list in the `ephpm_lab_v5_plugin_versions` WordPress option. Each published result must include that list.

`seed.php` creates the catalog, variable products, reviews, orders, blog content, menus, and benchmark pages. Counts are intentionally moderate enough for the small LKE cluster but large enough to exercise WooCommerce queries:

- 1,000 simple products
- 200 variable products with four variations each
- 2,000 reviews
- 300 blog posts
- 200 completed orders

The Kubernetes manifest is [k8s/wordpress-v5.yaml](../k8s/wordpress-v5.yaml). Use `bash scripts/apply-wordpress-v5.sh` to render the script and k6 ConfigMaps before applying it.
