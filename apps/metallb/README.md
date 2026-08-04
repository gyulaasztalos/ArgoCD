# MetalLB

BGP load balancer for the cluster. Peers with the router (`10.10.50.1`, AS 65000) from
AS 65001 and announces `10.10.50.30-39` (+ the matching IPv6 range).

- **Chart:** `metallb` 0.16.1 from <https://metallb.github.io/metallb> — Renovate keeps
  `targetRevision` current via the `argocd` manager.
- **BGP backend:** `frr-k8s` (bundled subchart, `frrk8s.enabled: true`). The legacy
  in-speaker FRR mode (`speaker.frr.enabled`) is deprecated upstream and stays off.

## Layout

```
application.yaml                 # multi-source Application (repo values + upstream chart + post-install)
values.yaml                      # full upstream 0.16.1 defaults, with our overrides marked by comments
post-install/
  ipaddresspools.yaml            # ipv4-pool 10.10.50.30-39, ipv6-pool fdbf:c39a:a943:50::30-39
  bgppeers.yaml                  # default (10.10.50.1) + default-v6, AS 65001 -> AS 65000
  bgpadvertisements.yaml         # one advertisement per family, pinned to its peer
  prometheus-rules.yaml          # BGP/BFD session alerts (see "Monitoring" below)
```

The four post-install CRs are a byte-for-byte port of what k3s-ansible applied
(`kubectl apply --dry-run=server` reports them all `unchanged` against the live cluster).
They stay outside the chart because MetalLB deliberately ships no config CRs.

## Migrating off k3s-ansible — do this before the first sync

Today MetalLB is **not** installed by Helm at all. k3s-ansible drops the whole rendered
manifest into `/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml`, so k3s's
auto-deploy controller owns it as an Addon:

```bash
kubectl get addon metallb-crds -n kube-system
# SOURCE: /var/lib/rancher/k3s/server/manifests/metallb-crds.yaml
```

Every object carries `objectset.rio.cattle.io/owner-name: metallb-crds`, and the k3s
deploy controller re-applies them on each server restart. If ArgoCD syncs while that file
is still on disk, the two controllers fight over the namespace forever.

The chart also renames everything (`controller` → `metallb-controller`,
`speaker` → `metallb-speaker`, plus a new `metallb-frr-k8s` daemonset), so the old objects
will not be adopted — they have to go.

**Expect a short LoadBalancer outage.** Switching from legacy FRR to frr-k8s tears down and
re-establishes both BGP sessions; `10.10.50.30-39` are unreachable in between. Do it from a
console/SSH session that does not route through Traefik.

**k3s does not clean up after itself here.** Removing the manifest file only stops future
deploys — [the docs are explicit](https://docs.k3s.io/installation/packaged-components):
"Deleting files out of this directory will not delete the corresponding resources from the
cluster", and a `.skip` file "will not remove or otherwise modify it or the resources it
created". Deleting the `Addon` CR does not cascade either: it carries no finalizer, and the
objects it applied have **no `ownerReferences`** — wrangler tracks them purely through the
`objectset.rio.cattle.io/*` annotations and the
`objectset.rio.cattle.io/hash=fc1016f2d449e33945c25d61c449a1c8b3278935` label.

So the teardown is explicit: remove the file first (so a k3s restart cannot re-apply it),
then delete the objects by hand. That label is the reliable way to enumerate them —
`kubectl get <kind> -l objectset.rio.cattle.io/hash=fc1016...` lists exactly what the addon
owns. See "Cutover runbook" below.

The metallb.io CRDs are deliberately **left in place**: the chart's `crds` subchart applies
over them, and deleting them would be a pointless extra failure mode. Their CR instances
disappear with the namespace and come back from `post-install/`.

Also drop the `metal_lb_*` block from `resources/my-cluster/group_vars/all.yml` (and the
matching file in the ansible repo) so a future playbook run does not put the manifest back.
The `metal_lb_*_tag_version` entries there are the last thing pinning MetalLB outside of
Git.

**Keep `--disable servicelb` in `extra_server_args`.** It has nothing to do with the
MetalLB role, but without it k3s starts klipper-lb, which competes with MetalLB for every
`type: LoadBalancer` Service. `--disable traefik` matters for the same reason (Traefik is
an ArgoCD app here). Both live in the `extra_server_args` block of `all.yml`, not in the
metallb block, so removing the latter leaves them untouched — just don't "tidy" them away.

The CRDs are cluster-scoped and shared: the chart's `crds` subchart re-applies
`metallb.io` CRDs, and the frr-k8s subchart adds `frrconfigurations.frrk8s.metallb.io`
which does not exist yet.

## Cutover runbook

Traefik loses its IP during this, so the ArgoCD UI is unreachable — drive it with the CLI
in `--core` mode, which talks to the Kubernetes API directly and needs no login and no
`argocd-server`. Core mode takes its namespace from the **current kubecontext**, so that
has to be `argocd`.

```bash
# 0. prepare the CLI (once)
kubectl config set-context --current --namespace=argocd
export ARGOCD_OPTS='--core'
argocd app list          # sanity check — should list every app

# 1. stop k3s from re-deploying MetalLB (run from the Ansible-Playbooks repo)
ansible 'Lana,Pam,Cheryl' -b --diff \
  -m file -a "path=/var/lib/rancher/k3s/server/manifests/metallb-crds.yaml state=absent"

# 2. tear down what the addon left behind
kubectl delete addon metallb-crds -n kube-system
kubectl delete namespace metallb-system
kubectl delete clusterrole,clusterrolebinding \
  -l objectset.rio.cattle.io/hash=fc1016f2d449e33945c25d61c449a1c8b3278935
kubectl delete validatingwebhookconfiguration metallb-webhook-configuration

# 3. confirm nothing but the CRDs survives
kubectl get ns metallb-system                     # expect: NotFound
kubectl get clusterrole,clusterrolebinding,validatingwebhookconfiguration \
  -l objectset.rio.cattle.io/hash=fc1016f2d449e33945c25d61c449a1c8b3278935

# 4. commit + push, then let ArgoCD take over
argocd app get app-of-apps --refresh --hard-refresh
argocd app sync app-of-apps
argocd app sync metallb
argocd app wait metallb --health --timeout 600
```

Both apps have `automated: {selfHeal, prune}`, so steps 4's syncs mostly just skip the
3-minute poll.

Verify afterwards:

```bash
kubectl get pods -n metallb-system -o wide       # 1 controller + 4 speaker + 4 frr-k8s
kubectl get svc -A --field-selector spec.type=LoadBalancer
# traefik must be back on 10.10.50.30, pihole on .31, transmission .32, postgres .33
```

## Monitoring

`prometheus.serviceMonitor.enabled: true` plus `frr-k8s.prometheus.serviceMonitor.enabled: true`
gives three ServiceMonitors (speaker, controller, frr-k8s). Since 0.16 the metrics
endpoints are **HTTPS-only on :9120/:9140** with a self-signed cert and bearer-token auth —
that is why ServiceMonitor is used over PodMonitor, why `tlsConfig.insecureSkipVerify`
stays `true`, and why `rbacPrometheus: true` is set on both the parent chart and the
subchart (the subchart has its own copy of `prometheus.serviceAccount`/`.namespace` —
the top-level block does not propagate into it).

The scraping service account is `monitoring-kube-prometheus-prometheus` in `monitoring`.
No `release:` label is needed — see the Prometheus auto-discovery note in the root
`CLAUDE.md`.

### Why one alert is redefined here

The chart's `MetalLBBGPSessionDown` reads `metallb_bgp_session_up{job=~"metallb.*"}`, which
only exists when the speaker owns the BGP session — i.e. legacy FRR mode. Under frr-k8s the
metric is `frrk8s_bgp_session_up` on the frr-k8s daemonset, so the shipped rule can never
fire. It is disabled in `values.yaml` and replaced in `post-install/prometheus-rules.yaml`.
The other chart alerts (stale config, config not loaded, pool exhausted, pool usage) are
unaffected and stay enabled.

## Resource limits

`resources: {}` everywhere, on purpose. The `metallb-system-resource-limits` LimitRange
supplies them (10m/64Mi request, 200m/256Mi limit, 64Mi min, 256Mi max) — same as under
the ansible install.

Be aware the container count per node goes **up** with frr-k8s: today the speaker pod holds
4 containers (speaker + frr + reloader + frr-metrics); afterwards it is 1 speaker container
plus a 5-container `metallb-frr-k8s` pod. With the LimitRange's 64Mi `defaultRequest`
that moves the reserved-but-mostly-unused footprint from 256Mi to 384Mi per node. The
LimitRange `min: 64Mi` is the binding constraint — you cannot request less per container
even by setting `resources` explicitly, so lowering that floor means editing the LimitRange
itself. Actual usage is ~80Mi per node today, so this is about schedulable headroom, not
real memory.

That LimitRange currently lives in `apps/multus/post-install/limitrange.yaml` and is owned
by the **multus** Application (see its `argocd.argoproj.io/tracking-id`). Moving it here
would need two commits — remove from multus and sync, then add here and sync — because two
Applications declaring the same object makes ArgoCD flap between them. Not worth doing
during the cutover.
