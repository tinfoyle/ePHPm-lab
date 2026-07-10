#!/bin/sh
set -eu

APP=/app

# The wp-cli image defaults its own PHP process to 128 MiB. WordPress core and
# a plugin-heavy fixture need more headroom while archives are unpacked.
wp() {
  command php -d memory_limit=512M /usr/local/bin/wp "$@"
}

WP="wp --path=$APP --allow-root"

apk add --no-cache git unzip >/dev/null

if [ ! -f "$APP/wp-load.php" ]; then
  wp core download --path="$APP" --version=7.0 --locale=en_US --allow-root
fi

mkdir -p "$APP/wp-content/mu-plugins" "$APP/wp-content/uploads"
cp /scripts/v5-benchmark.php "$APP/wp-content/mu-plugins/v5-benchmark.php"

cat > "$APP/wp-config.php" <<'PHP'
<?php
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wordpress' );
define( 'DB_PASSWORD', 'wordpress' );
define( 'DB_HOST', getenv( 'WORDPRESS_DB_HOST' ) ?: 'wordpress-v5-mysql' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

define( 'AUTH_KEY', 'wordpress-v5-auth-key' );
define( 'SECURE_AUTH_KEY', 'wordpress-v5-secure-auth-key' );
define( 'LOGGED_IN_KEY', 'wordpress-v5-logged-in-key' );
define( 'NONCE_KEY', 'wordpress-v5-nonce-key' );
define( 'AUTH_SALT', 'wordpress-v5-auth-salt' );
define( 'SECURE_AUTH_SALT', 'wordpress-v5-secure-auth-salt' );
define( 'LOGGED_IN_SALT', 'wordpress-v5-logged-in-salt' );
define( 'NONCE_SALT', 'wordpress-v5-nonce-salt' );

define( 'WP_HOME', 'http://wordpress-v5.local' );
define( 'WP_SITEURL', 'http://wordpress-v5.local' );
define( 'WP_ENVIRONMENT_TYPE', 'local' );
define( 'WP_DEBUG', false );
define( 'WP_DEBUG_DISPLAY', false );
define( 'DISABLE_WP_CRON', true );
define( 'WP_CACHE', true );
define( 'AUTOMATIC_UPDATER_DISABLED', true );
define( 'WP_AUTO_UPDATE_CORE', false );
define( 'FS_METHOD', 'direct' );

if ( getenv( 'CACHE_BACKEND' ) === 'redis' ) {
    define( 'WP_REDIS_HOST', getenv( 'REDIS_HOST' ) ?: 'wordpress-v5-redis' );
    define( 'WP_REDIS_PORT', 6379 );
    define( 'WP_REDIS_CLIENT', 'phpredis' );
    define( 'WP_REDIS_DATABASE', 0 );
    define( 'WP_REDIS_PREFIX', 'wordpress-v5:' );
}

$table_prefix = 'wp_';
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHP

for attempt in $(seq 1 90); do
  if php -r '$db = @new mysqli(getenv("WORDPRESS_DB_HOST") ?: "wordpress-v5-mysql", "wordpress", "wordpress", "wordpress"); exit($db->connect_errno ? 1 : 0);'; then
    break
  fi
  if [ "$attempt" = 90 ]; then
    echo 'MySQL did not become ready' >&2
    exit 1
  fi
  sleep 2
done

if ! $WP core is-installed >/dev/null 2>&1; then
  $WP core install \
    --url=http://wordpress-v5.local \
    --title='ePHPm Lab WooCommerce Fixture' \
    --admin_user=benchadmin \
    --admin_password=benchadmin123 \
    --admin_email=benchadmin@example.test \
    --skip-email
fi

$WP theme install oceanwp --version=4.2.1 --activate
$WP plugin install \
  woocommerce \
  elementor \
  ocean-extra \
  wordpress-seo \
  advanced-custom-fields \
  contact-form-7 \
  redis-cache \
  --activate
$WP option update ephpm_lab_v5_plugin_versions "$($WP plugin list --status=active --format=json)"
$WP plugin list --status=active --fields=name,version,status

$WP option update permalink_structure '/%postname%/'
$WP option update blogdescription 'Heavy WooCommerce fixture for ePHPm lab testing'
$WP option update woocommerce_default_country 'US:CA'
$WP option update woocommerce_currency 'USD'
$WP option update woocommerce_enable_guest_checkout 'yes'
$WP option update woocommerce_enable_checkout_login_reminder 'no'
$WP option update woocommerce_enable_coupons 'yes'
$WP option update woocommerce_hpos_enabled 'yes'
$WP rewrite flush --hard

if ! $WP option get ephpm_lab_v5_seed_version >/dev/null 2>&1; then
  $WP eval-file /scripts/seed.php
fi

# The setup image runs WP-CLI without the FPM Redis extension or ePHPm native
# functions, so activate the runtime-specific object-cache drop-in only after
# all WP-CLI setup and seed work is complete.
if [ "${CACHE_BACKEND:-}" = redis ]; then
  cp "$APP/wp-content/plugins/redis-cache/includes/object-cache.php" "$APP/wp-content/object-cache.php"
else
  rm -f "$APP/wp-content/object-cache.php"
  if [ ! -d "$APP/wp-content/cache-wordpress" ]; then
    git clone --depth 1 https://github.com/ephpm/cache-wordpress "$APP/wp-content/cache-wordpress"
  fi
  printf "%s\n" "<?php require __DIR__ . '/cache-wordpress/dropin/object-cache.php';" > "$APP/wp-content/object-cache.php"
fi

chown -R www-data:www-data "$APP/wp-content" 2>/dev/null || true
