# kube-vip: k3s-ansible → ArgoCD cutover

kube-vip provides the **control-plane VIP** (`fdbf:c39a:a943:50::20`), i.e. the
address in every kubeconfig and in archer's `--server` flag. It does nothing
else: `svc_enable=false`, so LoadBalancer services belong to MetalLB.

This migration deliberately makes **no functional change**. Chart 0.9.10 pins
appVersion `v1.0.4` — the exact image already running. The version bump to
v1.2.3 is a separate, later change, so that if the VIP misbehaves it is
unambiguous whether the migration or the upgrade caused it.

## Why this is not a normal "add an app" job

**1. The old DaemonSet cannot be adopted in place.** `spec.selector` is
immutable, and the two differ:

```
live:   name=kube-vip-ds   selector={name: kube-vip-ds}
chart:  name=kube-vip      selector={app.kubernetes.io/name, app.kubernetes.io/instance}
```

So ArgoCD creates a *second* DaemonSet rather than taking over the first.

**2. That overlap is safe, and is the point.** Both DaemonSets run the same
`v1.0.4` binary with the same env, so both contend for the same leader-election
lease:

```
lease/plndr-cp-lock  (kube-system)   holderIdentity=<node>   leaseDurationSeconds=25
```

Only one instance is ever leader, so the VIP is never assigned twice and never
drops. Deleting the old DaemonSet afterwards is therefore uneventful — this is
what makes a zero-gap cutover possible, and it only holds while both sides are
the same version. **Do not combine this step with the version bump.**

**3. Nothing owns the old objects.** The `Addon/vip` and `Addon/vip-rbac` CRs
and their source manifests under `/var/lib/rancher/k3s/server/manifests/` are
already gone, so the live DaemonSet has `ownerReferences: NONE`. Deleting it
will not be undone by k3s, and nothing will recreate it until the Ansible
playbook runs again.

## What differs from the live object (verified, intentional)

The rendered pod spec is field-for-field identical to the live one — image,
args, hostNetwork, serviceAccountName, priorityClassName, securityContext,
resources, tolerations, affinity, updateStrategy. Only three env vars change:

| env | live | rendered | why |
| --- | --- | --- | --- |
| `vip_cidr` | `128` | absent | **dead variable.** Not parsed by v1.0.4 (nor any later version); it has been ignored the whole time. |
| `vip_subnet` | absent | `128` | the key kube-vip actually reads. `128` is what the live VIP already resolves to (`fdbf:c39a:a943:50::20/128`). The chart default is `32`, which is IPv4-shaped and **wrong** for this VIP. |
| `vip_address` | absent | the VIP | the chart emits this whenever `cp_enable=true` and it cannot be suppressed. `address` is *also* set, so both `config.VIP` and `config.Address` carry the same value — they are separate fields in v1.0.4, not aliases. |

`securityContext.capabilities.drop` is set to `null` to strip the chart's
`["ALL"]` default, because the live container does not drop capabilities.
Restoring the chart default is tracked as follow-up hardening, not done here.

## Runbook

```bash
# 0. confirm the starting point
kubectl get ds -n kube-system kube-vip-ds
kubectl get lease -n kube-system plndr-cp-lock

# 1. commit + push. ArgoCD creates DaemonSet kube-vip alongside kube-vip-ds.
#    Both contend for plndr-cp-lock; the VIP does not move.
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-vip -w

# 2. verify the overlap is healthy BEFORE removing anything
kubectl get ds -n kube-system kube-vip kube-vip-ds
kubectl get lease -n kube-system plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
kubectl get nodes            # the API is still answering through the VIP

# 3. remove the old, unmanaged DaemonSet
kubectl delete ds -n kube-system kube-vip-ds

# 4. confirm the VIP survived the removal
kubectl get lease -n kube-system plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
kubectl get nodes
ssh <control-plane node> ip -6 addr show dev eth0 | grep fdbf:c39a:a943:50::20

# 5. drop the orphaned RBAC from the old install (the chart ships its own,
#    with byte-identical rules under different names)
kubectl delete clusterrole system:kube-vip-role
kubectl delete clusterrolebinding system:kube-vip-binding
```

`ServiceAccount/kube-vip` is **not** deleted — the chart declares the same name,
so ArgoCD adopts the existing object.

## If the VIP does not come back

ArgoCD talks to `https://kubernetes.default.svc`, not the VIP, so it keeps
working even when the VIP is down and can still sync a fix. External `kubectl`
and archer's `--server` connection are what break. The fastest manual recovery
is to point kubeconfig at a control-plane node address directly:

```bash
kubectl --server https://[<node-ipv6>]:6443 get ds -n kube-system
```

## Ansible-side follow-up

`roles/k3s_server/tasks/vip.yml` **stays**. It is what creates the VIP on a
fresh cluster, before ArgoCD exists — the same arrangement as MetalLB. After
bootstrap, ArgoCD's copy takes over and Renovate keeps it current.

The template still emits the dead `vip_cidr` env var; removing it there is
tracked as follow-up.
