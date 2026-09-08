#!/usr/bin/env bash
set -euo pipefail
ip netns list | grep -q '^ephpm-lab\b' || ip netns add ephpm-lab
ip -n ephpm-lab link set lo up
# Only this namespace's table is replaced, atomically; never flush the host ruleset.
ip netns exec ephpm-lab nft list table inet ephpm_lab >/dev/null 2>&1 || ip netns exec ephpm-lab nft add table inet ephpm_lab
ip netns exec ephpm-lab nft -f - <<'EOF'
flush table inet ephpm_lab
table inet ephpm_lab {
  chain output {
    type filter hook output priority 0; policy drop;
    oifname "lo" accept comment "Loopback ownership delegated to ePHPm BPF"
  }
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
  }
}
EOF
