#!/usr/bin/env bash
set -euo pipefail
grep -qx ephpm-wsl-multitenant-v1 /etc/ephpm-lab-instance
test "$(ps -p 1 -o comm=)" = systemd
test -r /sys/kernel/btf/vmlinux
test "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs
cd /opt/ephpm-lab
mkdir -p /var/cache/ephpm-lab /var/lib/ephpm-lab
url=$(jq -r .ephpmUrl versions.json)
digest=$(jq -r .ephpmSha256 versions.json)
archive=/var/cache/ephpm-lab/ephpm.tar.gz
if ! test -f "$archive"; then curl -fL --retry 3 "$url" -o "$archive"; fi
printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
mkdir -p /var/cache/ephpm-lab/release
tar -xzf "$archive" -C /var/cache/ephpm-lab/release
binary=$(find /var/cache/ephpm-lab/release -type f -name ephpm -print -quit)
test -n "$binary"
systemctl stop ephpm-lab.service 2>/dev/null || true
install -m 0755 "$binary" /usr/local/bin/ephpm
for account in ephpm-web ephpm-ctl; do
    id "$account" >/dev/null 2>&1 || useradd --system --user-group --home-dir "/var/lib/$account" --shell /usr/sbin/nologin "$account"
    install -d -m 0700 -o "$account" -g "$account" "/var/lib/$account"
done
install -d -m 0755 /etc/ephpm-lab/sites /srv/ephpm/default /srv/ephpm/sites
install -d -m 0700 -o ephpm-web -g ephpm-web /var/lib/ephpm-web/db
test -f /var/lib/ephpm-ctl/canary || openssl rand -hex 24 >/var/lib/ephpm-ctl/canary
chown ephpm-ctl:ephpm-ctl /var/lib/ephpm-ctl/canary
chmod 0600 /var/lib/ephpm-ctl/canary
for tenant in alice.lab.test bob.lab.test; do
    install -d -m 0750 -o ephpm-web -g ephpm-web "/srv/ephpm/sites/$tenant" "/srv/ephpm/sites/$tenant/public"
    printf '%s\n' "$tenant" >"/srv/ephpm/sites/$tenant/tenant-id"
    test -f "/srv/ephpm/sites/$tenant/canary" || openssl rand -hex 24 >"/srv/ephpm/sites/$tenant/canary"
    install -m 0644 tenant.php "/srv/ephpm/sites/$tenant/public/index.php"
    printf 'document_root = "public"\n' >"/etc/ephpm-lab/sites/$tenant.toml"
    chown -R ephpm-web:ephpm-web "/srv/ephpm/sites/$tenant"
    chmod 0600 "/srv/ephpm/sites/$tenant/canary"
done
# Extract only the benign PHP routes from the existing Kubernetes fixture.
python3 - <<'PY'
from pathlib import Path
import yaml
source = Path('assets/php-benchmark.yaml')
routes = {}
for doc in yaml.safe_load_all(source.read_text()):
    if doc and doc.get('kind') == 'ConfigMap':
        for key, value in doc.get('data', {}).items():
            if key in ('index.php', 'hello.php', 'cpu.php', 'json.php'):
                routes[key] = value
assert set(routes) == {'index.php', 'hello.php', 'cpu.php', 'json.php'}, 'Existing fixture routes missing'
for tenant in ('alice.lab.test', 'bob.lab.test'):
    for name, content in routes.items():
        # Preserve the fixture front controller without overwriting readiness.
        target = 'benchmark.php' if name == 'index.php' else name
        content = content.replace("'/index.php'", "'/benchmark.php'")
        Path('/srv/ephpm/sites', tenant, 'public', target).write_text(content)
PY
install -m 0644 ephpm.toml /etc/ephpm-lab/ephpm.toml
install -m 0644 ephpm-lab.service ephpm-lab-network.service /etc/systemd/system/
chmod 0755 network.sh
install -m 0755 labctl.sh /usr/local/sbin/ephpm-lab
systemctl daemon-reload
systemctl enable ephpm-lab-network.service ephpm-lab.service
systemctl start ephpm-lab.service
for attempt in $(seq 1 30); do
    if ip netns exec ephpm-lab curl -fsS --max-time 3 -H 'Host: alice.lab.test' http://127.0.0.1:8080/ >/dev/null 2>&1; then break; fi
    sleep 1
done
for tenant in alice.lab.test bob.lab.test; do
    ip netns exec ephpm-lab curl -fsS --max-time 3 -H "Host: $tenant" http://127.0.0.1:8080/ | jq -e --arg tenant "$tenant" '.tenant == $tenant and .status == "ready-for-test-planning" and .kv_available and .db_available'
done
bpftool -j cgroup show /sys/fs/cgroup/system.slice/ephpm-lab.service | jq -e '[.[].name] | contains(["vhost_bind4", "vhost_bind6", "vhost_connect4", "vhost_connect6"])'
/usr/local/sbin/ephpm-lab status | tee /var/lib/ephpm-lab/setup-status.txt
dpkg-query -W >/var/lib/ephpm-lab/packages.tsv
cp versions.json /var/lib/ephpm-lab/versions.json
echo 'SETUP COMPLETE. No adversarial tests or load tests executed.'
