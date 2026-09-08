# Security check execution ledger

Objective: perform the checks requested after the shared-temp and noisy-neighbor experiments. A passing narrow probe is not a blanket security claim. Preserve raw responses, positive controls, configurations, cleanup outcomes and untested deployment assumptions.

| Check | Required coverage | Status |
|---|---|---|
| Filesystem restriction bypass | Symlinks, traversal, stream wrappers, attempts to widen PHP/temp restrictions, peer and host canaries | Executed; tested filesystem controls passed |
| eBPF sidecar isolation | Own listener positive control; peer requested/actual ports; IPv4/IPv6, wildcard binds and address aliases | Executed twice; confirmed bypass NET-01 |
| Outbound restrictions | Mock metadata/internal endpoints, alternate representations and UDP; no actual external targets | Executed against isolated mock; lab firewall controls passed |
| Thread state leakage | Alternate/concurrent tenants; globals, environment, INI, cwd and error handlers | Executed; concurrent environment leak ENV-01 |
| Sessions/uploads | Same session IDs across tenants, multipart upload temp placement and peer access | Sessions/placement passed; live peer-upload fixture failed, corrected but not rerun |
| KV/database boundaries | Same keys/tables, peer credentials, alternate access routes | Native and MySQL cases passed; RESP disabled and untested |
| Vhost confusion | Host/authority conflict, forwarded headers, unusual hostnames, connection reuse | Executed; no tenant-scope mismatch; conflicting authority accepted |
| Management interfaces | Health, metrics, config, diagnostic and deployment access from tenant/public surfaces | Executed; readiness reachable through NET-01; diagnostics disabled |
| Preview build sandbox | Untrusted local build fixture, secrets, subprocesses, peer checkout, actual controller assumptions | Build fixture executed; inherited environment concern BUILD-01; controller reviewed as source evidence |
| Failure/cleanup | Failed policy attachment, restart, tenant deletion/recreation, stale sockets and ports | Restart checked; attachment fixture failed before BPF and awaits corrected rerun; recycle script unexecuted |
| Noisy neighbor mitigation | Repeat bounded workload with documented per-site rate/burst controls; restore baseline | Executed one full limited ladder; quiet-site p95 6.41 ms at load-8; baseline restored |
| Preview deployment review | Inspect available controller/build code and match the real deployment; identify missing production configuration explicitly | Pinned current repositories reviewed per user direction; no live controller integration test |

The current lab is native ePHPm v0.10.1 on Ubuntu WSL, per-request mode, shared Unix UID, dedicated offline network namespace, and systemd filesystem restrictions. It does not yet include a real GitHub preview controller, credentials, external ingress or a production-equivalent egress route. Do not silently replace those requirements with checks of an invented deployment.
