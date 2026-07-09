# Follow-Up: OPcache Cluster Tests

Date: 2026-07-09  
Author: Benjamin Pace

## Why This Follow-Up Exists

The original lab report was written from the outside looking in. I tested ePHPm the way a PHP-FPM-biased operator might: pull the public image, deploy some PHP apps, compare the result, then dig deeper when the first numbers looked disappointing.

That process exposed a useful gap. ePHPm's creator responded with fixes and new manifests focused on OPcache behavior, especially clustered OPcache invalidation.

This follow-up preserves the story rather than rewriting it. The earlier results still matter because they show what an outside operator encountered at the time. The new tests show how ePHPm is evolving and where the current architecture is starting to look more compelling.

## What Changed Upstream

We pulled upstream changes that added:

| File | Purpose |
| --- | --- |
| `k8s/opcache-cluster.yaml` | Two-node ePHPm StatefulSet with clustered OPcache invalidation. |
| `k8s/opcache-fpm-cluster.yaml` | Two-replica PHP-FPM/nginx control stack. |
| `k8s/k6-opcache-blip.yaml` | k6 jobs for the A/B blip test. |
| `k8s/opcache-cluster-test.sh` | Correctness test for cluster-wide OPcache invalidation. |
| `k8s/opcache-blip-test.sh` | Live-load comparison: ePHPm deploy invalidation vs PHP-FPM rolling restart. |
| `k8s/OPCACHE-CLUSTER.md` | Test documentation. |

The ePHPm side uses the published image:

```text
ephpm/ephpm:v0.4.0-php8.4
```

## Test Environment

The follow-up ran in the same LKE lab cluster shape:

| Item | Value |
| --- | --- |
| Cluster | Linode LKE |
| Nodes | 3 |
| Namespace | `opcache-demo` |
| ePHPm workload | `StatefulSet/opcache-demo`, 2 pods |
| PHP-FPM workload | `Deployment/opcache-fpm`, 2 replicas |
| Load tool | k6 |

The LKE control-plane ACL had to be updated first because my public IP changed. After that, the cluster was reachable and all nodes were Ready.

## Correctness Test

The correctness test warmed a PHP target on both ePHPm pods, ran one `ephpm deploy` on `opcache-demo-0`, and verified that both pods dropped the cached entry.

Result:

```text
PASS: one deploy on opcache-demo-0 invalidated OPcache on opcache-demo-0 opcache-demo-1
```

That is the important functional result. A single deploy signal on one pod propagated through the ePHPm cluster and invalidated OPcache on both nodes.

## A/B Blip Test

The A/B test compared two cache-bust approaches under live load:

| Runtime | Cache-bust mechanism |
| --- | --- |
| ePHPm | `ephpm deploy` on one pod, clustered OPcache invalidation propagates. |
| PHP-FPM | `kubectl rollout restart deployment/opcache-fpm`, because with `opcache.validate_timestamps=0`, process restart is the practical cache-bust. |

Rate: `50 iterations/s` for `120s`.

| Metric | ePHPm deploy | PHP-FPM rolling |
| --- | ---: | ---: |
| requests | 6001 | 6001 |
| failed | 0 | 0 |
| fail rate | 0.00% | 0.00% |
| avg | 1.06 ms | 2.19 ms |
| p95 | 2.47 ms | 5.57 ms |
| p99 | 5.98 ms | 13.63 ms |
| max | 21.75 ms | 40.50 ms |

Both stacks kept 100% availability at this rate. That matters: this was not a dramatic "PHP-FPM drops requests" result.

The useful finding is narrower and more operator-relevant:

- ePHPm invalidated OPcache across the cluster without restarting pods.
- PHP-FPM needed a rolling restart to clear OPcache in this test shape.
- ePHPm showed lower average, p95, p99, and max latency during the blip test.

## Portability Fix

The upstream blip script assumed a local kind image override:

```text
ephpm-v040-rc:final
```

That image was not pullable from LKE. The manifest's published image, `ephpm/ephpm:v0.4.0-php8.4`, worked and passed the correctness test.

I changed the script so the image override is optional:

```bash
EPHPM_IMAGE=ephpm-v040-rc:final bash k8s/opcache-blip-test.sh
```

If `EPHPM_IMAGE` is unset, the published image in the manifest is used. That makes the test portable to remote clusters like LKE while still supporting local kind experiments.

## Interpretation

This follow-up improves the story, but it does not justify overclaiming.

I would not summarize this as "ePHPm beats PHP-FPM now." The better summary is:

> The original lab exposed adoption and runtime-shape issues. ePHPm responded with clustered OPcache behavior that is genuinely promising, especially for operators who want cache invalidation without rolling PHP processes.

The repo now shows both sides of the open-source feedback loop:

1. An outside operator tested the project and found rough edges.
2. The project responded with targeted improvements.
3. The follow-up tests showed a more compelling ePHPm runtime shape.

That is a stronger story than pretending the first attempt was clean.

