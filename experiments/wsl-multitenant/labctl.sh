#!/usr/bin/env bash
set -euo pipefail
case "${1:-status}" in
  status)
    uname -r
    /usr/local/bin/ephpm --version
    systemctl is-active ephpm-lab.service
    ip -n ephpm-lab address show
    ip -n ephpm-lab route show table all
    bpftool cgroup show /sys/fs/cgroup/system.slice/ephpm-lab.service
    ip netns exec ephpm-lab nft list table inet ephpm_lab
    ;;
  get)
    tenant=${2:-alice.lab.test}
    case "$tenant" in alice.lab.test|bob.lab.test) ;; *) echo 'Use alice.lab.test or bob.lab.test' >&2; exit 2;; esac
    exec ip netns exec ephpm-lab curl -fsS -H "Host: $tenant" "http://127.0.0.1:8080${3:-/}"
    ;;
  logs) exec journalctl -u ephpm-lab.service -n 80 --no-pager ;;
  stop) exec systemctl stop ephpm-lab.service ;;
  start) exec systemctl start ephpm-lab.service ;;
  *) echo 'Usage: ephpm-lab {status|get [tenant] [path]|logs|stop|start}' >&2; exit 2 ;;
esac
