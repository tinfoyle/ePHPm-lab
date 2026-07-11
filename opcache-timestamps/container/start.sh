#!/bin/sh
# In-container entrypoint for the validate_timestamps bench.
#
# Generates the fixture into $DOCROOT (a composer-vendor-shaped require
# chain: N small class files + an index.php that require_once's every one
# of them), then execs `ephpm serve` with the selected variant config.
#
# Generating inside the container keeps the docroot on the container's
# own filesystem (overlayfs) by default — the same trick as the
# opcache-cluster.yaml seed-web.sh init container — and avoids host bind
# mounts entirely, which matters twice here:
#   1. stat() cost is exactly what this bench measures, so the docroot
#      filesystem must be stated (overlayfs vs named volume, see README);
#   2. on Windows/macOS podman machines a host bind mount goes through
#      virtiofs/9p and would measure the share protocol, not OPcache.
set -eu

: "${VARIANT:?set VARIANT to a-vt1-freq2 | b-vt1-freq60 | c-vt0}"
: "${DOCROOT:=/web}"
: "${NFILES:=500}"

mkdir -p "$DOCROOT/lib"

i=1
while [ "$i" -le "$NFILES" ]; do
    n=$(printf '%04d' "$i")
    cat > "$DOCROOT/lib/C${n}.php" <<PHP
<?php
class C${n} {
    const REV = 1;
    public static function label(): string { return 'c-${n}-' . (${i} * 7919); }
}
function c${n}_hash(string \$seed): string {
    return hash('sha256', \$seed . C${n}::label() . C${n}::REV);
}
PHP
    i=$((i + 1))
done

cat > "$DOCROOT/index.php" <<PHP
<?php
header('Content-Type: application/json');
\$checksum = 'seed';
for (\$i = 1; \$i <= ${NFILES}; \$i++) {
    \$n = sprintf('%04d', \$i);
    require_once __DIR__ . "/lib/C{\$n}.php";
    \$fn = "c{\$n}_hash";
    \$checksum = \$fn(\$checksum);
}
echo json_encode([
    'checksum' => \$checksum,
    'includes' => ${NFILES},
    'rev' => C0001::REV,
]);
PHP

# Introspection endpoint: the driver asserts the variant's ini pair actually
# took effect (a config knob that silently no-ops would otherwise produce
# three identical measurements and a bogus conclusion).
cat > "$DOCROOT/status.php" <<'PHP'
<?php
header('Content-Type: application/json');
$s = function_exists('opcache_get_status') ? opcache_get_status(false) : null;
echo json_encode([
    'opcache_enabled' => is_array($s) ? (bool) ($s['opcache_enabled'] ?? false) : false,
    'validate_timestamps' => (string) ini_get('opcache.validate_timestamps'),
    'revalidate_freq' => (string) ini_get('opcache.revalidate_freq'),
]);
PHP

exec ephpm serve --config "/bench/configs/${VARIANT}.toml"
