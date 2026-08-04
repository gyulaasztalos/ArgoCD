# MetalLB: k3s-ansible → ArgoCD cutover

Completed 2026-08-04. Kept as a record — the same reasoning applies to any other component
still deployed by k3s auto-deploy manifests.

Before: MetalLB v0.15.3 in **legacy FRR mode**, installed by TechnoTim's k3s-ansible.
After: chart 0.16.1 with the **frr-k8s** backend, owned by ArgoCD.

## Why it was not a normal "add an app" job

MetalLB was not Helm-installed at all. k3s-ansible drops the whole rendered manifest into
`/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml`, so k3s's auto-deploy controller
owned it as an Addon and re-applied it on every server restart:

```bash
kubectl get addon metallb-crds -n kube-system
# SOURCE: /var/lib/rancher/k3s/server/manifests/metallb-crds.yaml
```

Three consequences:

1. **Two controllers would fight.** ArgoCD syncing while that file was still on disk meant
   an endless apply war over the namespace.
2. **Nothing would be adopted.** The chart renames everything — `controller` →
   `metallb-controller`, `speaker` → `metallb-speaker`, plus an entirely new
   `metallb-frr-k8s` daemonset — so the old objects had to be deleted, not upgraded.
3. **k3s does not clean up after itself.**
   [The docs are explicit](https://docs.k3s.io/installation/packaged-components):
   *"Deleting files out of this directory will not delete the corresponding resources from
   the cluster"*, and a `.skip` file *"will not remove or otherwise modify it or the
   resources it created"*. Deleting the `Addon` CR does not cascade either — it carries no
   finalizer, and the objects it applied have **no `ownerReferences`**. Wrangler tracks
   them only through the `objectset.rio.cattle.io/*` annotations and the
   `objectset.rio.cattle.io/hash=fc1016f2d449e33945c25d61c449a1c8b3278935` label.

That label was the reliable way to enumerate what to delete:
`kubectl get <kind> -l objectset.rio.cattle.io/hash=fc1016...`.

## Pre-flight: the DNS deadlock

CoreDNS forwards to the node's `/etc/resolv.conf`. If the nodes had resolved via the
in-cluster Pi-hole on `10.10.50.31`, that IP would have vanished with MetalLB — and then
ArgoCD could not resolve `github.com` or `metallb.github.io`, and containerd could not pull
`quay.io/metallb/*:v0.16.1` or the (entirely new) frr-k8s images. MetalLB could not come
back because MetalLB was down.

The escape hatch was the standalone Pi-hole on `10.10.50.5` (the nebula-sync replica
target). Checked before starting:

```bash
ansible 'Lana,Pam,Cheryl,Archer' -b -m command -a "cat /etc/resolv.conf" \
  | grep -E "SUCCESS|nameserver"
```

The kubeconfig points at `https://[fdbf:c39a:a943:50::20]:6443` — a literal address — so
`kubectl` and `argocd --core` were never at risk.

**Anything else deployed this way inherits the same trap.** Check
`kubectl get addons -A` before migrating the next component.

## The runbook as executed

Traefik loses its IP during the cutover, so the ArgoCD UI is unreachable. `argocd --core`
talks to the Kubernetes API directly — no login, no `argocd-server`, no ingress. It takes
its namespace from the **current kubecontext**, which therefore has to be `argocd`.

```bash
# 0. CLI prep
kubectl config set-context --current --namespace=argocd
export ARGOCD_OPTS='--core'
argocd app list

# 1. stop k3s re-deploying MetalLB (from the Ansible-Playbooks repo).
#    Archer is a worker — no server/manifests dir — so it is excluded.
ansible 'Lana,Pam,Cheryl' -b --check --diff \
  -m file -a "path=/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml state=absent"
ansible 'Lana,Pam,Cheryl' -b --diff \
  -m file -a "path=/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml state=absent"

# 2. explicit teardown
kubectl delete addon metallb-crds -n kube-system
kubectl delete namespace metallb-system
kubectl delete clusterrole,clusterrolebinding \
  -l objectset.rio.cattle.io/hash=fc1016f2d449e33945c25d61c449a1c8b3278935
kubectl delete validatingwebhookconfiguration metallb-webhook-configuration

# watch it drain
kubectl get pods -n metallb-system -w
kubectl get ns   metallb-system -w

# 3. confirm only the CRDs survive
kubectl get ns metallb-system                      # NotFound
kubectl get clusterrole,clusterrolebinding,validatingwebhookconfiguration \
  -l objectset.rio.cattle.io/hash=fc1016f2d449e33945c25d61c449a1c8b3278935

# 4. commit + push, then hand over
argocd app get  app-of-apps --refresh --hard-refresh
argocd app sync app-of-apps                        # creates the metallb Application
argocd app sync metallb
argocd app wait metallb --health --timeout 600
```

The 9 `metallb.io` CRDs were deliberately left in place — the chart's `crds` subchart
applies over them, and deleting them would have been a pointless extra failure mode. Their
CR instances died with the namespace and came back from `post-install/`.

## Verification

```
argocd app get metallb                  Synced / Healthy
kubectl get pods -n metallb-system      1 controller + 4 speaker + 4 frr-k8s (5/5) + 1 statuscleaner
LoadBalancer IPs                        traefik .30, pihole .31, transmission .32, postgres-rw-lb .33
addon leftovers                         none; addon metallb-crds NotFound
Prometheus targets                      13 up (4 speaker + 1 controller + 8 frr-k8s endpoints)
BGP IPv4 -> 10.10.50.1                  Established on all 4 nodes
```

IPs came back identical because the Services carry explicit `spec.loadBalancerIP` and the
pool ranges were ported unchanged.

## Ansible-side follow-up

Drop the `metal_lb_*` block from `resources/my-cluster/group_vars/all.yml` and the matching
file in the ansible repo, so a future playbook run cannot put the manifest back. The
`metal_lb_*_tag_version` entries there were the last thing pinning MetalLB outside Git.

**Keep `--disable servicelb` in `extra_server_args`.** Nothing to do with the MetalLB role,
but without it k3s starts klipper-lb, which competes with MetalLB for every
`type: LoadBalancer` Service. `--disable traefik` matters for the same reason. Both live in
the `extra_server_args` block, not the metallb block — don't tidy them away.
