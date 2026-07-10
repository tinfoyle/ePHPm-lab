#!/bin/sh
set -eu

apt-get update
apt-get install -y --no-install-recommends libzip-dev
docker-php-ext-install -j"$(nproc)" mysqli pdo_mysql opcache zip
pecl install redis
docker-php-ext-enable redis
rm -rf /var/lib/apt/lists/* /tmp/pear

cat > /usr/local/etc/php/conf.d/wordpress-v5.ini <<'INI'
memory_limit=512M
opcache.enable=1
opcache.enable_cli=0
opcache.validate_timestamps=0
opcache.jit=0
realpath_cache_size=4096K
realpath_cache_ttl=600
upload_max_filesize=16M
post_max_size=16M
INI

exec php-fpm -F
