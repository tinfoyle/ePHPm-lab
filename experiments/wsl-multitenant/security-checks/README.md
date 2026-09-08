# Security review checkpoint

Start with [findings and evidence](FINDINGS.md) and the [coverage ledger](PLAN.md). This is an ongoing review of pinned repository revisions, not a completed security audit. The surrounding [WSL experiment](../README.md) provisions the lab; these probes run separately.

Run a bounded check from PowerShell:

```powershell
./experiments/wsl-multitenant/security-checks/Run-Checks.ps1 -Check network
```

Checks include `network`, `php-boundaries`, `outbound`, `routing`, `build`, `storage`, `lifecycle`, `mitigation`, and `recycle`. Use only the dedicated EPHPM-Lab instance. Mutating checks serialize on a guest lock and restore their configuration in normal exception cleanup. `mitigation` requires the earlier noisy-neighbor fixtures. HTTP/2 routing requires guest package `python3-h2`. The wrapper has a five-minute outer bound; an externally killed process may require operator inspection/restoration.

`storage` and `lifecycle` contain corrections after fixture failures which have not yet been rerun. `recycle` is an unexecuted draft. Exported evidence is a checkpoint and may represent a partial run; inspect cases and the ledger rather than treating the existence of evidence.json as a pass. `-CollectOnly -Check <name> -RunId <id>` exports an existing run without executing probes.

Results contain synthetic canaries, HTTP responses, configuration and cleanup records. No real application secrets were used. Source checkouts and runtime binaries are excluded from Git. Historical run evidence remains immutable except the first lifecycle inventory was narrowed to relevant vhost programs to omit unrelated WSL kernel inventory; the full original remains in the guest.
