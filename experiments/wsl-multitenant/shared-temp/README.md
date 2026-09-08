# Shared temporary-path check

**Observed result: no shared-path writes or cross-tenant reads/writes succeeded through the tested PHP APIs.** Both sites can write inside their own container and private temp/session directories.

[Full report](results/20260908T223011Z/REPORT.md) · [Raw evidence, warnings, integrity hashes and cleanup](results/20260908T223011Z/evidence.json)

| Target | Alice and Bob |
|---|---|
| Direct `/tmp` | Denied by `open_basedir` |
| Direct `/var/tmp` | Denied by `open_basedir` |
| `/dev/shm` | Denied by `open_basedir` |
| Shared `/var/lib/ephpm-web` | Denied by `open_basedir` |
| Shared `/srv/ephpm/sites` parent | Denied by `open_basedir` |
| Own site container | Write/readback succeeded |
| Own private temp/upload/session directories | Write/readback succeeded |
| Other tenant's existing canaries | Reads and append attempts denied in both directions |
| `tempnam(sys_get_temp_dir(), ...)` and `tmpfile()` | Succeeded in tenant-private temp |
| `tempnam('/tmp', ...)` | Denied |

Alice's temp directory was `/tmp/ephpm-vhosts/alice.lab.test-f608fc08338292b9/tmp`; Bob's was `/tmp/ephpm-vhosts/bob.lab.test-9c7fab4e84dc9443/tmp`. PHP's `open_basedir` was restricted to each site's container and corresponding private state root.

The operator separately created synthetic `/tmp` and `/var/tmp` controls under the **same Unix UID and mount namespace as ePHPm**. Both creations succeeded. Tenant PHP still could not read or append to those controls. Thus an unwritable filesystem is not the explanation: these PHP operations were blocked by `open_basedir`. Both tenants share a UID, and systemd `PrivateTmp` is per service, not per tenant.

All 12 existing canaries were unchanged after the cross-access attempts. All 21 tracked paths, including four probe endpoints, were removed or verified absent (see the raw cleanup ledger for the exact entries). The `tmpfile()` handles were closed in PHP and their temporary files automatically removed.

## Reproduce

```powershell
./experiments/wsl-multitenant/shared-temp/Run-Probe.ps1
```

The wrapper transfers only this probe directory, uses network-only `nsenter` inside EPHPM-Lab, bounds execution to 60 seconds, and exports results. `-CollectOnly -RunId 20260908T223011Z` retrieves existing results without repeating the probes. The Python harness holds a lock, uses random-prefix exclusive-create canaries, verifies actual file existence before cross-access, snapshots content, and cleans up in `finally`. It never changes the runtime configuration or overwrites pre-existing files. Raw evidence stays in `/var/lib/ephpm-lab/shared-temp/<run-id>` and the repository's `results/` directory.

## Scope

This is a direct filesystem/API check against ePHPm v0.10.1 / PHP 8.4.23 in the existing hardened per-request configuration. It is not proof against every filesystem escape. Symlink races, uploads, PHP session semantics, native-extension behavior, sandboxed preview builds and attempts to change PHP restrictions remain untested. Successful OS controls were operator instrumentation, not an escape achieved by tenant code.
