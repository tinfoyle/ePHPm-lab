#!/usr/bin/env bash
set -euo pipefail
grep -qx ephpm-wsl-multitenant-v1 /etc/ephpm-lab-instance
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq systemd systemd-sysv dbus ca-certificates curl jq python3 python3-yaml iproute2 nftables linux-tools-generic libcap2-bin procps util-linux openssl
# Ubuntu's /usr/sbin wrapper wants tools matching uname (a Microsoft kernel in WSL).
# bpftool itself is a userspace client; use the packaged ELF executable directly.
bpf_binary=$(find -L /usr/lib/linux-tools -type f -name bpftool | sort -V | tail -1)
test -n "$bpf_binary"
ln -sf "$bpf_binary" /usr/local/sbin/bpftool
cat >/etc/wsl.conf <<'EOF'
[boot]
systemd=true
[automount]
enabled=false
mountFsTab=false
[interop]
enabled=false
appendWindowsPath=false
[user]
default=root
EOF
# Neither guest needs remote login or discovery services.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
