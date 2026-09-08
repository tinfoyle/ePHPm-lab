#!/usr/bin/env bash
set -euo pipefail
grep -qx ephpm-wsl-multitenant-v1 /etc/ephpm-lab-instance
systemctl is-active --quiet ephpm-lab.service
cd /opt/ephpm-lab/noisy-neighbor
exec 9>/run/ephpm-noisy-neighbor.lock
flock -n 9 || { echo 'Another noisy-neighbor experiment is running' >&2; exit 1; }
for tenant in alice.lab.test bob.lab.test; do
    install -m 0644 cpu.php "/srv/ephpm/sites/$tenant/public/noisy-cpu.php"
    printf 'static-control\n' >"/srv/ephpm/sites/$tenant/public/control.txt"
done
run_id=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p /var/lib/ephpm-lab/noisy-neighbor
# 3 alternating-role trials by default, 30 seconds per phase, ~9 minutes plus drain.
# Whole process group is bounded even if a client stalls unexpectedly.
timeout --signal=TERM --kill-after=10s 15m nsenter --net=/run/netns/ephpm-lab -- \
    python3 run.py --seconds 30 --trials "${1:-3}" --output "/var/lib/ephpm-lab/noisy-neighbor/$run_id"
{
    /usr/local/bin/ephpm --version
    systemctl show ephpm-lab.service --property=ActiveState,SubState,MemoryMax,CPUQuotaPerSecUSec,TasksMax,NetworkNamespacePath
} >"/var/lib/ephpm-lab/noisy-neighbor/$run_id/environment.txt"
