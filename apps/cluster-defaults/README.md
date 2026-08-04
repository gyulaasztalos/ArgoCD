# cluster-defaults

Namespace-level policy that belongs to no single application — the things a
namespace needs regardless of what is deployed into it.

Single-source app: hand-written manifests under `install/`, no upstream chart.
Sync-wave `-3`, ahead of everything else, because these are **admission-time**
defaults — a LimitRange only affects pods created after it exists, so it has to
be in place before the workloads it applies to.

## Contents

| file | what |
| --- | --- |
| `install/limitrange.yaml` | `kube-system` container defaults: 10m/32Mi request, 200m/512Mi limit, 32Mi-512Mi bounds |

## Why this app exists

The `kube-system` LimitRange used to live in `apps/multus/post-install/`, owned by
the multus Application for no better reason than multus being the app that
targeted `kube-system`. When multus was decommissioned
(`resources/unused/multus/`) that policy needed a home that was not tied to a
workload's lifecycle.

Anything similar — a namespace-wide LimitRange, ResourceQuota, or default
NetworkPolicy that is cluster policy rather than app config — belongs here rather
than being tucked into whichever app happens to sit in that namespace.

Per-app namespaces keep owning their own LimitRange (see
`apps/metallb/post-install/limitrange.yaml`); this app is only for namespaces no
single application owns.
