# Experiment: multi-tenant ePHPm on WSL2

The setup script provisions the environment only; it never starts probes or load tests. The separately invoked [noisy-neighbor proof](noisy-neighbor/README.md) measures cross-tenant resource interference. No security certification is implied by either.

The [shared temporary-path check](shared-temp/README.md) tests direct writes to shared directories and cross-tenant access to disposable canaries.

The first completed run and its WSL-specific caveat are recorded in [the setup record](SETUP-2026-09-08.md).

## Reproduce

From PowerShell at the repository root, with WSL2 already installed:

```powershell
./experiments/wsl-multitenant/New-Lab.ps1
```

The default instance is **EPHPM-Lab**. The script imports a clean, checksum-pinned Ubuntu Base 24.04.4 amd64 rootfs, installs systemd and diagnostic tools, then installs checksum-pinned ePHPm v0.10.1 / PHP 8.4.23. The corresponding upstream commit is recorded in `versions.json`. It does not clone an existing distro or inherit its credentials. Registration and disk storage default to `$env:LOCALAPPDATA/WSL/EPHPM-Lab`; the rootfs cache is in the repository's ignored `.generated/wsl-multitenant` directory.

The script refuses an existing instance unless `-Resume` is supplied. Resume requires this experiment's guest marker, reapplies setup, preserves canaries and database files, and restarts only this lab's service/distro. It does not reset other WSL distributions or change global WSL settings. Choose another `-Name EPHPM-LabSomething` for a fresh reproduction. The instance name is a Windows registration label; each guest uses the same internal service/namespace names.

Rootfs and runtime archives are pinned; apt packages receive current Ubuntu updates, so provisioning is repeatable but not bit-for-bit identical. `/var/lib/ephpm-lab/packages.tsv` records installed package versions. Ubuntu userspace does **not** choose the WSL kernel; kernel, BTF and BPF attachment observations are recorded separately in `setup-status.txt`.

## Environment

| Component | Configuration |
| --- | --- |
| Runtime | Native Linux ePHPm systemd service, per-request mode, four PHP threads |
| Sites | `alice.lab.test`, `bob.lab.test` under `/srv/ephpm/sites` |
| HTTP roots | Each site's `public/`, selected by root-owned overrides in `/etc/ephpm-lab/sites` |
| Data-plane identity | `ephpm-web`, shared by both tenants as in upstream's vhost architecture |
| Control-plane fixture | Separate `ephpm-ctl` identity and private synthetic canary; no preview controller or GitHub App installed |
| State | Per-site embedded Turso databases configured under `/var/lib/ephpm-web/db`, native KV; RESP disabled |
| Host controls | systemd filesystem sandbox, private temp/devices, no-new-privileges, 2 GiB memory / 200% CPU / 256-task service limits |
| Network | Dedicated `ephpm-lab` Linux network namespace, loopback only, no veth or external route; nftables denies non-loopback traffic |
| Tenant network policy | ePHPm eBPF enabled, CAP_BPF/CAP_NET_ADMIN, unlimited memlock, sidecar range 20000–29999, quota eight |
| Windows integration | Drive automount and executable interoperability disabled in this distro; `/mnt` inaccessible to the serving process |

The namespace's loopback is deliberately handed to ePHPm's BPF policy. The systemd unit cannot start until the namespace/firewall setup succeeds. We do not weaken `ebpf_policy` when loading fails. Firewall changes are confined to this namespace and its own table; no host-wide flush or rule changes occur.

This is an **offline service topology**: provisioning downloads run as the guest operator outside the service namespace. Tenant HTTP has no public internet/DNS access. This protects the surrounding local lab, but differs from Luther's public-egress preview fleet. A later review must explicitly model public egress, DNS, ingress/TLS, external databases, build execution and control-plane credentials. Network namespace isolation is an outer lab boundary, not evidence that ePHPm's tenant isolation works.

WSL shares a kernel and some host integration with your other distributions. This guest is not a full VM boundary for kernel exploits. No hostile payload is installed or executed during provisioning.

## Use and pause

No Windows hosts-file changes or externally exposed HTTP ports are needed. Run requests inside the lab network namespace through the helper:

```powershell
wsl -d EPHPM-Lab -u root -- /usr/local/sbin/ephpm-lab status
wsl -d EPHPM-Lab -u root -- /usr/local/sbin/ephpm-lab get alice.lab.test
wsl -d EPHPM-Lab -u root -- /usr/local/sbin/ephpm-lab get bob.lab.test
wsl -d EPHPM-Lab -u root -- /usr/local/sbin/ephpm-lab logs
wsl -d EPHPM-Lab -u root -- /usr/local/sbin/ephpm-lab stop
wsl -d EPHPM-Lab -u root -- /usr/local/sbin/ephpm-lab start
```

For an operator shell: `wsl -d EPHPM-Lab -u root`. This is privileged lab administration; it is not a tenant security boundary. Setup starts a hidden idle `wsl ... sleep infinity` client because systemd services alone do not keep WSL running. Its Windows PID is recorded in `.generated/wsl-multitenant/EPHPM-Lab-keepalive.pid`. `wsl --terminate EPHPM-Lab` stops this distro and the idle client. Services are enabled and will start when it next boots; keep an operator shell open when manually using it after termination. There is intentionally no automatic destructive teardown command; WSL unregistering deletes the distro's data.

## Existing assets reused

- `k8s/php-benchmark.yaml`: setup extracts its hello, CPU and JSON routes. The existing front controller becomes `benchmark.php` so it does not overwrite the new tenant readiness endpoint.
- `wordpress-v5/`: copied to `/opt/ephpm-lab/assets/wordpress-v5` for later adaptation. WordPress, plugins, worker mode and k6 runs are **not** installed/executed by this experiment. The historical startup scripts still contain old config keys and must be migrated before use.
- New readiness endpoint: returns the tenant ID, PHP version and availability of native DB/KV functions without accessing another tenant or performing attacks.
- New private canaries: generated only inside the guest, outside public roots, with no real credentials.

Both tenants deliberately share the serving UID; per-tenant files and state rely on ePHPm's boundaries. Separate Unix users for each tenant would change the architecture under review. The two OS identities here represent data plane versus control plane.

## Stop point

Provisioning still stops at readiness. Subsequent authorized experiments are recorded separately: [noisy-neighbor proof](noisy-neighbor/PROOF.md), [shared-temp checks](shared-temp/README.md), and the [security findings checkpoint](security-checks/FINDINGS.md).

Setup checks archive integrity, systemd readiness, BTF/cgroup availability, HTTP readiness for both sites, attached BPF program inventory and namespace firewall state. These are installation checks, not a proof of filesystem, network, database, session, or cache isolation. Even Landlock enforcement remains a later verification item: no tenant build command is run during setup.

Next work is a jointly agreed test plan covering the exact production configuration, attack assumptions, test fixtures and evidence requirements. No preview webhook, real repository build, external callback, exploitation or fuzzing is started automatically.

Sources: [Ubuntu Base images](https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/), [ePHPm release](https://github.com/ephpm/ephpm/releases/tag/v0.10.1), [upstream hardening guide](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/site/content/guides/multi-tenant-hardening.md), [upstream eBPF guide](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/site/content/guides/ebpf-per-vhost-network.md).
