#!/bin/sh
set -eu

WORKER_COUNT="${WORKER_COUNT:-2}"
case "${WORKER_COUNT}" in
  *[!0-9]*|'')
    echo "WORKER_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

cat > /tmp/wordpress-v5-worker.toml <<'TOML'
[server]
listen = "0.0.0.0:8080"
document_root = "/var/www/html"
index_files = ["index.php"]
fallback = ["$uri", "$uri/", "/index.php"]

[server.request]
max_body_size = 16777216
max_header_size = 16384
trusted_hosts = ["wordpress-v5-ephpm-worker", "wordpress-v5-ephpm-worker.wordpress-v5", "wordpress-v5.local", "localhost", "127.0.0.1"]

[server.security]
blocked_paths = ["/vendor/*", "/wp-config.php"]
open_basedir = false
disable_shell_exec = true

[php]
mode = "worker"
worker_script = "vendor/bin/ephpm-wp-worker"
worker_populate_superglobals = true
worker_count = __WORKER_COUNT__
worker_max_requests = 250
worker_backlog = 128
worker_boot_timeout = 90
max_execution_time = 30
memory_limit = "512M"
ini_overrides = [
  ["display_errors", "Off"],
  ["error_reporting", "E_ALL"],
  ["realpath_cache_size", "4096K"],
  ["realpath_cache_ttl", "600"],
]

[server.limits]
max_connections = 200
per_ip_rate = 1000.0
per_ip_burst = 200

[kv]
memory_limit = "128MB"
eviction_policy = "allkeys-lru"
TOML

sed -i "s/__WORKER_COUNT__/${WORKER_COUNT}/" /tmp/wordpress-v5-worker.toml

exec ephpm serve --config /tmp/wordpress-v5-worker.toml
