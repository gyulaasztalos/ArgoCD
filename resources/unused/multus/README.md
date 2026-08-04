# multus (decommissioned)

Kept as reference only. Not registered in `apps/kustomization.yaml`, so ArgoCD does not
deploy it.

Multus CNI existed for exactly one consumer: **homebridge**, which needed a macvlan
interface onto the IoT VLAN (`eth0.20`) so HomeKit accessories could reach it on the LAN.
Home Assistant took that role over and homebridge was decommissioned
(`resources/unused/homebridge/`), leaving multus with nothing attached to it.

`post-install/multus-iot.yaml` is that macvlan NetworkAttachmentDefinition — master
`eth0.20`, bridge mode, static IPAM with a route to `10.10.0.0/16` via `10.10.20.1`. If a
future workload needs the IoT VLAN again, this is the shape it took.

The `kube-system` LimitRange that used to live in `post-install/limitrange.yaml` was
**not** multus-specific — it only lived here because multus was the app targeting
`kube-system`. It moved to `apps/cluster-defaults/` and is still active.

## Removing it from a running cluster — order matters

> Getting this wrong takes down **pod creation cluster-wide**. Read the whole section
> before starting.

Multus is not a passive add-on. With `multusConfFile: auto` it writes
**`00-multus.conflist`** (note: `.conflist`, not `.conf`) into
`/var/lib/rancher/k3s/agent/etc/cni/net.d/`, which sorts ahead of
`10-flannel.conflist` — so it is the *delegating* CNI for every pod, chaining down to
flannel as `cbr0`. Confirm with:

```bash
kubectl get pods -A -o json \
  | jq -r '.items[] | select(.metadata.annotations["k8s.v1.cni.cncf.io/network-status"]) | .metadata.name' \
  | wc -l          # if this equals your pod count, multus is in the datapath
```

**The fallback is exact.** `00-multus.conflist` delegates to a network literally named
`cbr0` whose plugin chain — `flannel` + `portmap` + `bandwidth`, `cniVersion` 1.0.0,
`hairpinMode`/`forceAddress`/`isDefaultGateway` — is character-for-character what
`10-flannel.conflist` already defines standalone. Removing multus therefore does not
reconfigure pod networking; it removes a pass-through. Verified on all four nodes, and
`10-flannel.conflist` is present on every one of them.

The trap: this is the **thin** plugin (`thickPlugin.enabled: false`). The multus binary
lives on disk at `/var/lib/rancher/k3s/data/cni/multus` (49MB), is invoked by containerd,
and authenticates to the API server on its own using
`multus.d/multus.kubeconfig` — the only file in that directory, and one the DaemonSet
refreshes periodically. Deleting the ServiceAccount and RBAC while `00-multus.conflist` is
still on the nodes leaves a CNI config pointing at a binary that can no longer
authenticate — every subsequent CNI ADD fails and **no new pod can start on any node**.
Running pods keep their networking, which makes it look fine until something restarts.

So the config file must come off the nodes *before* the RBAC goes.

Note the multus Application has no `resources-finalizer.argocd.argoproj.io`, so removing it
from `apps/kustomization.yaml` deletes only the Application — the DaemonSet and friends are
orphaned, still running. That is convenient here: Git can be updated with no immediate
effect on the cluster, and the teardown driven by hand afterwards.

### Runbook

```bash
# 1. Git first. Commit the move + the cluster-defaults app, then:
argocd app get app-of-apps --refresh --hard-refresh
argocd app sync app-of-apps
argocd app sync cluster-defaults      # kube-system LimitRange must land BEFORE step 4
argocd app list | grep -E "multus|cluster-defaults"
kubectl get limitrange -n kube-system  # kube-system-resource-limits must be present
# the multus Application is gone; its DaemonSet is still running and untouched.

# 2. Re-check the nodes (verified 2026-08-04: all four had exactly this).
ansible 'Lana,Pam,Cheryl,Archer' -b \
  -m command -a "ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d/"
# Expect 00-multus.conflist, 10-flannel.conflist, and a multus.d/ directory.
# If 10-flannel.conflist is MISSING on any node, stop — there is no fallback config
# and removing 00-multus.conflist would leave that node with no CNI at all.

# 3. Stop multus regenerating its config, but leave RBAC intact.
kubectl delete daemonset multus -n kube-system
# New pods still work at this point: the on-disk binary + kubeconfig are still valid.

# 4. Remove the config so containerd falls back to flannel.
ansible 'Lana,Pam,Cheryl,Archer' -b --diff \
  -m file -a "path=/var/lib/rancher/k3s/agent/etc/cni/net.d/00-multus.conflist state=absent"
ansible 'Lana,Pam,Cheryl,Archer' -b --diff \
  -m file -a "path=/var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d state=absent"
# Both must report changed=true. A "changed=false" here means the path was wrong —
# do NOT continue, or step 6 will strand a live 00-multus.conflist without RBAC.

# 5. PROVE pod creation works on every node before going further.
kubectl create deployment cni-check --image=busybox --replicas=8 -- sleep 3600
kubectl get pods -l app=cni-check -o wide      # must reach Running on all 4 nodes
kubectl get pods -l app=cni-check -o json | jq -r \
  '.items[].metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "no multus annotation (good)"'
kubectl delete deployment cni-check
# If pods hang in ContainerCreating, DO NOT continue — see rollback.

# 6. Only now remove the rest. Explicit names — see the note below on why.
kubectl delete serviceaccount multus -n kube-system
kubectl delete clusterrole rke2-multus
kubectl delete clusterrolebinding rke2-multus
kubectl delete configmap -n kube-system multus-v4.2.418-config
kubectl delete network-attachment-definitions.k8s.cni.cncf.io multus-iot -n kube-system
kubectl delete crd network-attachment-definitions.k8s.cni.cncf.io

# 7. Optional: drop the 49MB binary from each node.
ansible 'Lana,Pam,Cheryl,Archer' -b --diff \
  -m file -a "path=/var/lib/rancher/k3s/data/cni/multus state=absent"
```

**Use explicit names in step 6, not label selectors.** Verified against the live cluster:
the ServiceAccount carries **no labels at all**, the DaemonSet is labelled
`app=rke2-multus,tier=node`, and neither uses `app.kubernetes.io/instance`. A selector-based
delete silently matches nothing and leaves the RBAC behind. Also note the ConfigMap name is
chart-version-suffixed (`multus-v4.2.418-config`) — re-check it with
`kubectl get all,sa,cm -n kube-system | grep -i multus` if the chart was bumped since this
was written.

Deleting the CRD in step 6 is safe: `multus-iot` in `kube-system` is the only
NetworkAttachmentDefinition in the cluster.

### Rollback

Until step 6, recovery is quick — re-register `application.yaml` in
`apps/kustomization.yaml`, sync, and multus rewrites `00-multus.conflist` on every node. After
step 6 the RBAC is gone too, but a re-sync recreates all of it; nothing here is stateful.

If pods are stuck in `ContainerCreating` at step 5, check
`journalctl -u k3s -n 100` on the affected node and confirm `00-multus.conflist` is really gone
and `10-flannel.conflist` is really present. containerd re-reads the CNI directory on
change, so no k3s restart should be needed — but `systemctl restart k3s` (control-plane) /
`k3s-agent` (Archer) forces it.
