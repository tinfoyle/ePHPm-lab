# Findings — security review checkpoint, 2026-09-08

This is a live record, not the completion report. Runtime tested: ePHPm v0.10.1 / PHP 8.4.23, commit `a0bcd4104996f43118407383c884777c93758712`. The user selected current repository contents as the deployment reference. Controller references: switchboard `f27811897fa9f6637c8c71c9569683c0bdbbec3f`, switchboard-api `477e89327da4d53fee6b85fe6c469d0aef81fd6a`.

## NET-01 — loopback aliases bypass tenant sidecar ownership

**Confirmed; high impact for a multi-tenant preview service relying on this policy.**

Alice's PHP request created a TCP sidecar. Alice could connect through its virtual and assigned real port. Bob was correctly denied on `127.0.0.1` / `::1`, but received Alice's unique canary using an alternate loopback address. This is actual application data transfer, not merely a successful TCP handshake.

- With wildcard IPv4/IPv6 listeners, Bob could reach the real port using `127.0.0.2` and `::ffff:127.0.0.1`.
- With Alice bound specifically to `127.0.0.1`, Bob still received Alice's marker through `::ffff:127.0.0.1` at the assigned real port.
- A listener bound specifically to `::1` did not accept the tested IPv4/mapped connections; those failures were transport refusal, not policy enforcement.

Evidence: [initial matrix](results/20260908T224322Z-network/evidence.json), [repeat with localhost-only controls](results/20260908T224442Z-network/evidence.json). Probe listeners and PHP endpoints were removed after each run; the implementation's existing port assignment maps remain until restart.

The source matches the observation: `vhost_connect4` recognizes only exact `127.0.0.1`, and `vhost_connect6` only exact `::1`; `do_connect` allows addresses classified as non-loopback without consulting sidecar ownership. See [the tested BPF implementation](https://github.com/ephpm/ephpm/blob/a0bcd4104996f43118407383c884777c93758712/crates/ephpm-server/bpf/vhostnet.bpf.c).

Fix direction: recognize the entire IPv4 loopback range and normalize IPv4-mapped IPv6 before the ownership decision. Add regression tests with localhost-only and wildcard listeners, own/peer positive and negative controls, and direct real ports. Do not assume blocking only `127.0.0.1` and `::1` covers loopback.

## ENV-01 — concurrent tenants share putenv values

**Confirmed; potential cross-tenant disclosure of application environment secrets.**

A tenant set a synthetic, uniquely named environment value with `putenv()` and held the request open for 500 ms. The other tenant's overlapping requests read that exact value via `getenv()`. This reproduced in three rounds in each direction. No actual secret was used or read. The value generally vanished after the mutating request completed; request-end restoration does not protect overlapping requests.

Evidence: [PHP boundary matrix](results/20260908T224742Z-php-boundaries/evidence.json), cases `overlapping request state`, plus baseline and after-shutdown controls. Global PHP variables and the tested precision/include-path/error-handler/cwd settings did not show the same cross-tenant marker behavior in this run.

Deployment relevance: the current switchboard source generates environment bootstrap code exporting resolved values through `$_SERVER`, `$_ENV`, and `putenv()` (generated env body in `src/deployer.rs`, around line 1320). If application secrets are included, concurrent tenant PHP can potentially read them by name. A root secret file need not be directly readable for this path to matter.

Fix direction: remove process-global environment mutation from the multi-tenant data path, use request-local configuration and SAPI variables, and evaluate disabling tenant `putenv` where compatibility allows. Merely restoring values at request end is insufficient. A process boundary is another option where applications require process-global environment behavior.

## BUILD-01 — inherited controller environment reaches sandboxed builds

**Sandbox behavior reproduced; controller impact supported by repository inspection.** The build fixture received a synthetic environment value inherited from its parent after ePHPm dropped to UID 995 and applied Landlock. Own-file read/write succeeded, peer-file read/append and a subprocess peer read were denied, and the peer canary remained intact. An unknown site failed closed. See [build evidence](results/20260908T225440Z-build/evidence.json).

At the pinned switchboard revision, `SandboxExec::command` in `src/deployer.rs` creates a command without clearing inherited environment; `run_build` and seed execution use this command. `src/secrets.rs` supports operator secrets in `SWITCHBOARD_SECRET_*`. The fork gate withholds manifest secret resolution, but does not remove those inherited variables. Therefore environment-backed daemon secrets can reach an allowed fork build even when fork secret resolution is disabled. No real controller credentials were used, and the full GitHub deployment path was not exercised. The checked-in probe now uses the representative variable name `SWITCHBOARD_SECRET_LAB_CANARY`; the recorded run used `SECURITY_BUILD_PARENT_CANARY`.

Fix direction: start builds with an explicit environment allowlist and add a fork-build regression using a synthetic daemon secret. File-based secrets and other credential paths require their own checks. The current controller already wraps builds with `ephpm exec`; an older comment claiming builds run directly as root is not evidence about this revision.

## Load mitigation result

The original uncapped proof measured quiet-site PHP p95 rising from roughly 7–10 ms to 573–627 ms with eight busy requests. With documented per-site limits of 5 requests/second and burst 20, a fresh 30-second-per-phase ladder measured quiet-site p95 **7.74 ms baseline, 6.41 ms at eight busy clients, 8.42 ms recovery**, with zero errors/deadline misses among 360 quiet PHP requests. [Limited-run evidence](results/20260908T230108Z-mitigation/evidence.json), [phase summary](results/20260908T230108Z-mitigation/load/summary.json).

This is one mitigation trial versus three original trials, for the fixed CPU fixture. Rate limiting mitigated this workload; it is not a per-tenant CPU or memory boundary. The baseline configuration was restored afterward.

## Other checks and limits

- Filesystem: own-file, own-symlink and own stream-wrapper controls succeeded. Peer paths, traversal, symlinks, wrappers, `/proc/self/root` and attempts to widen the tested INI restrictions failed. [Evidence](results/20260908T224742Z-php-boundaries/evidence.json).
- Sessions/uploads: identical file-session IDs remained tenant-specific; uploads used private temp paths and disappeared after request completion. A later live peer-upload test stopped on a fixture ownership error; that additional check is **not complete**.
- Native KV/Turso and MySQL: same names returned tenant-specific values. Changing the MySQL username to the peer with the caller's password failed authentication. `USE peer` was accepted but still returned the caller's rows. The storage run completed these cases and cleaned tables before its upload fixture error. RESP was disabled and was not tested. [Storage evidence](results/20260908T231851Z-storage/evidence.json).
- Outbound: a separate mock namespace served metadata/internal TCP and UDP controls. Root controls reached it; tenant attempts, including decimal/hex/mapped forms, did not deliver requests. Firewall state was restored exactly. This verifies the lab's external firewall, not production egress. [Evidence](results/20260908T225941Z-outbound/evidence.json).
- Routing: tested Host forms, forwarded headers and reused HTTP/1 and HTTP/2 connections kept tenant identity and filesystem scope consistent. Conflicting HTTP/2 `:authority` and `Host` selected `Host`; reject such ambiguity at ingress, but this run did not prove an isolation bypass. Health/readiness/primary endpoints were public; request diagnostics were disabled. Some guessed admin URLs returned the tenant front controller, not an admin API. Mapped loopback reached runtime readiness from tenant PHP, extending NET-01. [Evidence](results/20260908T225243Z-routing/evidence.json).
- Restart: the HTTP listener closed, vhost BPF programs disappeared, and both sites were healthy after restart. Missing-capability attempts failed earlier on a MySQL port conflict and then invalid config, so they **do not prove** policy attachment fails closed. The corrected fixture awaits rerun. [Latest lifecycle evidence](results/20260908T231842Z-lifecycle/evidence.json).
- The third-tenant quota/deletion/recreation script is drafted but unexecuted. Controller source review covered build wrapping, inherited environment, fork gates, signature verification, allowlist and drain-token checks; it was not a full controller test-suite run or deployed webhook integration test.

Luther is fixing NET-01 according to the user. No fix revision has been fetched or verified here. These results remain against the pinned pre-fix runtime. Review is ongoing; this checkpoint is not a security clearance for public previews.
