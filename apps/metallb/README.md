# MetalLB

BGP load balancer for the cluster. Peers with the router (`10.10.50.1`, AS 65000) from
AS 65001 and announces `10.10.50.30-39` (+ the matching IPv6 range).

- **Chart:** `metallb` from <https://metallb.github.io/metallb>, rendered by kustomize
  (`helmCharts:` in `kustomization.yaml`) rather than an ArgoCD Helm source, so the
  frr-k8s liveness probe can be patched (see "FRR liveness probe"). Renovate keeps
  `version` current via its `kustomize` manager. Needs `kustomize.buildOptions:
  --enable-helm` in argocd-cm (`apps/argocd/values.yaml`).
- **BGP backend:** `frr-k8s` (bundled subchart, `frrk8s.enabled: true`). The legacy
  in-speaker FRR mode (`speaker.frr.enabled`) is deprecated upstream and stays off.

Migrated off the k3s-ansible install on 2026-08-04 — see [MIGRATION.md](MIGRATION.md) for
why that was not a normal "add an app" job, and for the trap any other k3s auto-deploy
component will hit.

## Layout

```
application.yaml                 # single-source Application, path: apps/metallb (kustomize)
kustomization.yaml               # renders the chart (helmCharts) + post-install/ + patches/
values.yaml                      # full upstream defaults, with our overrides marked by comments
patches/
  frr-liveness-probe.yaml        # replaces the chart's frr /livez probe (see "FRR liveness probe")
post-install/
  kustomization.yaml             # lists everything below — an omitted file gets PRUNED
  ipaddresspools.yaml            # ipv4-pool 10.10.50.30-39, ipv6-pool fdbf:c39a:a943:50::30-39
  bgppeers.yaml                  # default (10.10.50.1) + default-v6, AS 65001 -> AS 65000
  bgpadvertisements.yaml         # one advertisement per family, pinned to its peer
  limitrange.yaml                # metallb-system container defaults (see "Resource limits")
  prometheus-rules.yaml          # BGP/BFD session alerts (see "Monitoring")
  metallb-dashboard.json         # Grafana dashboard, ConfigMap-generated (see "Dashboard")
```

The pool/peer/advertisement CRs are a byte-for-byte port of what k3s-ansible applied. They
live outside the chart because MetalLB deliberately ships no config CRs.

Pool names are load-bearing: live Services carry
`metallb.io/ip-allocated-from-pool: ipv4-pool`, so renaming `ipv4-pool` would re-allocate
every LoadBalancer IP.

## Monitoring

`prometheus.serviceMonitor.enabled: true` plus `frr-k8s.prometheus.serviceMonitor.enabled: true`
gives three ServiceMonitors (speaker, controller, frr-k8s) = 13 scrape targets. Since 0.16
the metrics endpoints are **HTTPS-only on :9120/:9140** with a self-signed cert and
bearer-token auth — that is why ServiceMonitor is used over PodMonitor, why
`tlsConfig.insecureSkipVerify` stays `true`, and why `rbacPrometheus: true` is set on both
the parent chart and the subchart (the subchart has its own copy of
`prometheus.serviceAccount`/`.namespace` — the top-level block does not propagate into it).

`podMonitor.enabled` must stay `false`: the chart hard-fails if both monitor types are
enabled, and only the ServiceMonitor path wires up the bearer token.

The scraping service account is `monitoring-kube-prometheus-prometheus` in `monitoring`.
No `release:` label is needed — see the Prometheus auto-discovery note in the root
`CLAUDE.md`.

### Metric names differ by backend

Under frr-k8s the BGP/BFD metrics are exposed by the frr-k8s daemonset with a `frrk8s_`
prefix, **not** the legacy `metallb_bgp_*` names:

| what | metric | job |
| --- | --- | --- |
| pool allocation | `metallb_allocator_addresses_{in_use_,}total` | `metallb-controller-monitor-service` |
| speaker state | `metallb_speaker_announced`, `metallb_k8s_client_*` | `metallb` |
| BGP session | `frrk8s_bgp_session_up`, `frrk8s_bgp_announced_prefixes_total` | `metallb-frr-k8s-frr-k8s-monitor-service` |

This is why the chart's `MetalLBBGPSessionDown` alert is disabled in `values.yaml` — it
reads `metallb_bgp_session_up{job=~"metallb.*"}`, which only exists when the speaker owns
the BGP session (legacy FRR mode), so it could never fire. The replacement lives in
`post-install/prometheus-rules.yaml`. The other chart alerts (stale config, config not
loaded, pool exhausted, pool usage) are unaffected and stay enabled.

`frr-k8s.prometheus.serviceMonitor.metricRelabelings` can rename `frrk8s_bgp_*` back to
`metallb_bgp_*` if a dashboard or alert needs the legacy names — left off deliberately.

## Dashboard

`post-install/metallb-dashboard.json`, generated into a ConfigMap by the kustomization and
discovered by the Grafana sidecar (`grafana_dashboard: "1"`, folder `Kubernetes`). UID
`metallb-bgp`.

Written from scratch rather than imported. The one community dashboard worth considering,
[grafana.com #20162](https://grafana.com/grafana/dashboards/20162-metallb/), covers pool and
k8s-client metrics but its whole middle section is `metallb_layer2_*` — never emitted in BGP
mode — and it has **no BGP panels at all**, which is the part that matters here. Upstream
MetalLB and frr-k8s ship no dashboard.

Layout: a row of current-state tiles (sessions established, `ipv4-pool` usage, IPs
allocated, config health), then a state timeline of BGP sessions per node, then announced
prefixes beside a table of which node is announcing which service IP, then UPDATE and
API-client rates. Pool-usage thresholds are set to 75/85/95 to match the chart's
`MetalLBAddressPoolUsage` alerts, so the gauge changes colour exactly when the alert fires.

The BGP panels key on a `node` label that the frr-k8s metrics do not natively carry — it is
added by `frr-k8s.prometheus.serviceMonitor.relabelings` in `values.yaml`, copied from the
scrape target's pod metadata. Without that relabeling the legends render blank.

## The IPv6 peer is parked, not broken

`frrk8s_bgp_session_up{peer="fdbf:c39a:a943:50::"} == 0` on all four nodes; `vtysh -c
"show bgp summary"` reports the neighbour stuck in `Connect`, `never` up. The IPv4 session
to `10.10.50.1` is Established everywhere.

This is **left in place deliberately** — it is the remnant of an unfinished dual-stack
build-out, kept so the work can be picked up later. It predates the ArgoCD migration and
was simply invisible before, because nothing scraped MetalLB. The peer address came from
`metal_lb_bgp_peer_address_v6` in the old ansible vars, and `fdbf:c39a:a943:50::` is the
subnet-router anycast address of the /64 — a questionable thing to peer with, and the first
thing to revisit when dual-stack resumes. No IPv6 LoadBalancer Service exists (`ipv6-pool`:
0 of 10 assigned), so nothing is affected today.

Because it can never come up as configured, `MetalLBBGPSessionDown` in
`post-install/prometheus-rules.yaml` excludes it (`peer!="fdbf:c39a:a943:50::"`) — otherwise
it would fire continuously and train everyone to ignore the alert. **Remove that matcher
when dual-stack is finished**, or the real v6 session going down will be silent. The
dashboard deliberately still *shows* the peer, so it is visible without being noisy.

## FRR liveness probe

The chart hardcodes the `frr` container's liveness probe as `httpGet /livez` (only the
period and threshold are values), and `/livez` stays green through both known ways BGP
gets stuck after a network blip. `patches/frr-liveness-probe.yaml` swaps it for an exec
probe aimed at the 2026-11-05 failure. After a switch firmware update flapped eth0, zebra
kept the connected `10.10.50.0/24` route at `eth0 inactive` while the kernel had eth0 up.
bgpd then reported `No path to specified Neighbor` and never reconnected.

The probe fails only when kernel `operstate` is `up` **and** zebra's *connected*
`10.10.50.0/24` route is not selected and installed (`C>*` in `show ip route connected`).
It has to be the connected entry. bgpd resolves the UDM peer only through that one, and
during the second switch update that day, archer also had a kernel-learned copy of the
route that was active. An earlier version of the probe grepped the route JSON for
`"active":true`. It matched that copy and passed, while BGP stayed down with
`10.10.50.1` unresolved. The container has no jq or python, so the probe parses vtysh's
text output, which is worth re-checking on FRR upgrades. During a genuine switch or UDM outage, eth0 is
down or the route is fine, so it passes and causes no restart loops. A hung zebra or vtysh
also fails it, which covers what `/livez` checked. After 10 × 30 s ≈ 5 min, kubelet
restarts the `frr` container. FRR's config survives that, because it lives on the pod's
`frr-conf` volume.

The probe does **not** cover the 2026-09-01 failure, where FRR's runtime config was wiped
but the neighbour state was otherwise sane. That one is still a manual
`kubectl delete pod` of the affected frr-k8s pods, alerted by `MetalLBBGPSessionDown`.

The interface name (`eth0`) and the subnet are hardcoded in the patch. Update them if the
node NIC or the LB network ever changes.

When bumping the chart, check that the frr container is still named `frr` in the
`metallb-frr-k8s` DaemonSet. The patch is a strategic merge keyed on that name, and if
the name changed it would add a stray container entry instead of patching the real one.
Rendering with `kustomize build --enable-helm apps/metallb` shows this.

## Resource limits

`resources: {}` everywhere, on purpose. `post-install/limitrange.yaml` supplies them
(10m/64Mi request, 200m/256Mi limit, 64Mi min, 256Mi max) — same values as under the
ansible install, moved here from `apps/multus/post-install/` during the migration.

frr-k8s raises the container count per node: the old speaker pod held 4 containers
(speaker + frr + reloader + frr-metrics); it is now 1 speaker container plus a
5-container `metallb-frr-k8s` pod. At the LimitRange's 64Mi `defaultRequest` that moves the
reserved-but-mostly-unused footprint from 256Mi to 384Mi per node. The `min: 64Mi` is the
binding constraint — you cannot request less per container even by setting `resources`
explicitly, so lowering that floor means editing the LimitRange itself. Actual usage is
~80Mi per node, so this is about schedulable headroom, not real memory.
