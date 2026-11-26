# Known issues, fingerprints and accepted noise

> **Site-specific.** The baselines, the accepted noise and some failure modes below describe
> the original homelab (4× Pi 5 8GB, k3s). On another cluster, re-baseline and prune this
> file as described in `../ADAPTING.md`, step 5.

Use this file to classify what `healthcheck.sh` found. For each finding, decide:
**accepted noise** (mention briefly), **known failure mode** (name it and point to its
memory note), or **new** (investigate). Memory notes are named by their slug. They live in
the project's auto-memory and are listed in `MEMORY.md`. Read a note before acting on its
failure mode, because it holds the details and past decisions.

The baselines below were taken on 2026-11-19. When the cluster changes (new apps, upgraded
hardware, changed reservations), update them here instead of re-deriving them every run.

## Healthy baselines

| Metric | Healthy | Warning | Incident seen |
|---|---|---|---|
| Watches per apiserver | 500–1,100, total ~2,400 | one >1,400 sustained for hours | 1,500–1,740 on one, ~150 on another |
| apiserver (k3s) RSS | 2.0–2.8 GiB | >3.5 GiB | 4.6–5.1 GiB |
| MemAvailable, control plane | 1.6–2.5 GiB | <1.2 GiB | 0.26 GiB |
| MemAvailable, archer | 2.0–3.0 GiB | <1.2 GiB | — |
| Major faults/s (10m rate) | <100 | >300 for more than one sample | 1,600–3,800 |
| etcd leaders | exactly 1 | — | 2 (split, after restarts) |
| etcd leader changes | 0, or 1–2 per k3s restart | changes without a restart | several per hour |
| etcd WAL fsync p99 | <0.03 s | >0.1 s | — |
| Longhorn volumes | all `healthy` (16 as of 11-19) | `degraded` | `faulted` |
| Longhorn backups | `default`-group volumes backed up daily ~02:00, all <26h old | any STALE | — |
| Container WS / memory limit | <75% | >85% for hours, since it thrashes before any OOM | Rancher 97–99% → lost lease |
| Rancher working set (live limit 1800Mi) | <1.5 GiB | >1.65 GiB | 1.79 GiB → restart |
| Free request headroom | the biggest pod (prometheus, 2112Mi) fits on ≥1 node after a reshuffle | no node can take the biggest pod | prometheus Pending |

Allocatable is 5514Mi on the control-plane nodes (kube-reserved 1536Mi + system-reserved
512Mi) and 7050Mi on archer. Swap is OFF on all nodes, so memory trouble shows up as major
faults (file-page thrash) and evictions, not as swap use.

## Accepted noise (report in one line, don't investigate)

- **Watchdog** firing: the dead man's switch, always on. If it is NOT firing, that is the
  problem. (`alerting-topology-kuma-and-deadmans-switch`)
- **KubeCPUOvercommit / KubeMemoryOvercommit**: firing since the 2026-11-14 right-sizing.
  Requests intentionally sum past what a node loss could absorb.
- **ArgoAppNotSynced rancher / app `rancher` sync=Unknown**: every Rancher chart ≤2.15.3
  declares `kubeVersion < 1.37` and the cluster runs 1.37.2. Rancher keeps running; only
  syncing is blocked. (`rancher-limit-thrash-and-kubeversion-gate`, `k3s-auto-minor-upgrades-stable-channel`)
- **Rancher at its memory limit** (≈98% of 1800Mi, restarts roughly every 4–5 days with `leaderelection lost`, KubeAggregatedAPIDown `v1.ext.cattle.io` for a few minutes): the owner decided on 2026-11-23 to leave Rancher as is until a Rancher release supports k3s 1.37. Report the restart in one line and don't propose fixes. (`rancher-limit-thrash-and-kubeversion-gate`)
- **TargetDown nut-exporter**: since 2026-07-24. The exporter times out against upsd, and
  it still scrapes the removed Keor UPS. A separate task was offered for it.
- **helm-install-gateway-api-crd FailedCreate** in kube-system: blocked by the LimitRange
  since the 1.37 upgrade. The owner chose to ignore it. (`k3s-gateway-api-crd-job-ignored`)
- **IPv6 BGP sessions down** (peer `fdbf:c39a:a943:50::`, all 4 nodes): parked on
  purpose. The UDM config (`resources/bgp.conf`, identical to the live one as of 11-19) is
  IPv4-only, because dual-stack was never finished, and no IPv6 LoadBalancer exists. See
  `apps/metallb/README.md`, "The IPv6 peer is parked, not broken". Only
  `peer="10.10.50.1"` matters.
- **Longhorn instance-managers on `longhorn-critical`**: expected until the next Longhorn
  upgrade or node drain. The `system-node-critical` setting only applies to idle
  recreation. (`control-plane-swap-thrash-follows-watches`, "path 1")
- **EtcdIsVoter=True** node condition: informational, not pressure.

## Known failure modes and their fingerprints

### Control-plane watch imbalance → memory collapse
`control-plane-swap-thrash-follows-watches`

How it shows:
- One apiserver holds >1,400 watches for hours while another has a few hundred.
- That node's k3s RSS climbs toward 4–5 GiB and its major faults rise into the hundreds or thousands per second.
- Then come etcd "receiving database snapshot", `leaderelection lost` exits of k3s, and the watches cascade to the next node.

Mitigation in place: `--kube-apiserver-arg=goaway-chance=0.001`. After a k3s restart the imbalance should fade within about 70 minutes. If it persists for many hours, goaway is not doing its job, and that is new information.

### Rancher hits its own memory limit
`rancher-limit-thrash-and-kubeversion-gate`

How it shows:
- KubeAggregatedAPIDown for `v1.ext.cattle.io`.
- The rancher container terminates with reason=Error exit=1, and `kubectl logs --previous` ends in `[FATAL] leaderelection lost for cattle-controllers`.
- archer (or whichever node hosts Rancher) shows a major-fault spike while the node still has plenty of MemAvailable.

Confirm with:
```promql
container_memory_failures_total{failure_type="pgmajfault",scope="container",namespace="cattle-system"}
```
and Rancher's working set against its limit. This is not node pressure.

### Kubelet eviction ranking hits the wrong pod
`control-plane-swap-thrash-follows-watches`

How it shows:
- `Evicted` events.
- A hard eviction takes pods whose usage exceeds their request. The worst case is the Longhorn instance-manager, which stops every engine and replica on that node, so volumes degrade and the CNPG primary fails over.

Fix pattern: right-size the requests of the evicted pods. The rule is request = max(p95×1.2, peak×0.8), rounded up to 16Mi, with a 32Mi floor.

### LonghornNodeDown from kubelet memory pressure (not a storage outage)
Seen on 2026-11-23, lana, 08:02–08:20 CET.

Longhorn marks its node not-ready whenever the Kubernetes node reports MemoryPressure. The Longhorn node events read "Kubernetes node X has pressure: KubeletHasInsufficientMemory", then "Waiting for disk … to be ready". The engines and replicas keep running and the volumes stay healthy.

Confirm with:
```bash
kubectl get events -n longhorn-system --field-selector involvedObject.name=<node>
```
Then find what pushed MemAvailable under ~1 GiB.

On the Prometheus node, the usual trigger is the TSDB head compaction every 2 h (07:00Z, 09:00Z, …), which adds 200–350 MiB of RSS for a few minutes. It bites when it coincides with watches moving onto that node's apiserver, or with slow growth of the node's pods.

### ESO webhook restarts every 5 min (cert lookahead > renewBefore)
How it shows: the `external-secrets-webhook` pods show `Completed exit=0`, with hundreds of restarts. Their logs end in "certs are not valid at now + lookahead, triggering shutdown" (`certLookahead` 2160h).

The webhook's default lookahead is 90 days, while cert-manager's `renewBefore` is 360h. So once the self-signed cert has less than 90 days left (from 2026-11-22), the webhook shuts down on every cert check. The fix is `webhook.lookaheadInterval` < `renewBefore`, in `apps/external-secrets/values.yaml`.

### Pending pod from fragmentation
How it shows: a large pod (usually prometheus at 2112Mi) is Pending after a rollout reshuffle, although the free memory summed across the cluster would fit it.

Check the per-node free headroom section. The fix is to move a smaller pod off one node, which needs the owner's consent.

### Native sidecars missing from request sums
CNPG pods carry `plugin-barman-cloud` as an initContainer with `restartPolicy: Always`, so a postgres pod requests postgres + 256Mi. `healthcheck.sh` already counts these. Hand-written sums must count them too.

### Longhorn strict-local phantom replica
`longhorn-strict-local-phantom-replica`

How it shows: after node MemoryPressure, a strict-local volume gets an unschedulable duplicate replica, and its snapshots and backups fail with "BUG: replica should be 1". Look for not-Completed Longhorn backups or a degraded volume.

### frr-k8s BGP not self-healing
`frrk8s-bgp-no-autoheal`

How it shows: `frrk8s_bgp_session_up{peer="10.10.50.1"} == 0` on a node, or LoadBalancer IPs (Traefik .30, Pi-hole .31) are unreachable after a network blip. The fix is deleting the broken frr-k8s pod, which needs consent.

### Pi 5 macb TX-queue hang
`rpi5-macb-tx-queue-hang`

How it shows:
- A node goes NotReady or unreachable while it still has link.
- ARP and IPv6 NDP are INCOMPLETE from the other nodes.
- The kernel log counts `NETDEV WATCHDOG` / `transmit queue timed out` lines.

ssh fails while the hang lasts. `nic-watchdog.service` handles the cases the driver doesn't recover from.

### NFS backup target stale or hung
`nfs-soft-mount-tuning-scope`

How it shows: Longhorn backups failing, high load with processes stuck in D state, or `EBADHANDLE` errors.

### k3s auto-upgrade surprises
`k3s-auto-minor-upgrades-stable-channel`

How it shows: the node versions changed since the last check, or apiservers have recent start times with no restart anyone knew about. A minor jump can break charts that have a `kubeVersion` gate.

### Renovate auto-merge breaking an app
How it shows: a CrashLoopBackOff that starts right after a Renovate merge.

Check:
```bash
git log --since=<window> origin/main
```
Then read the release notes of the bumped image. Example: paperless-ngx 3.5.0 restricted ALLOWED_HOSTS, see `paperless-allowed-hosts-3-5`. `healthcheck.sh` prints the merges in the window.

Renovate's `automergeSchedule` allows weekdays 05:00–16:00 plus weekends (Europe/Budapest). Until 2026-11-26, `platformAutomerge: true` let GitHub merge as soon as checks passed, at any hour (11-25 20:43 authentik, 11-26 01:52 traefik). It is `false` since then, so Renovate merges itself, only inside the window. A merge outside the window is now itself a finding: check `renovate.json` for a reverted `platformAutomerge` and the PR's `mergedBy` (a human merge is fine). (`renovate-platform-automerge-ignores-schedule`)

### Rollout co-locates real usage on one control-plane node
`control-plane-swap-thrash-follows-watches`

How it shows: right after a merge, a node's pod working set jumps by ~1 GiB without any pod growing, because the rollout's new pods (e.g. authentik server + worker) both landed there. MemAvailable sits under 1 GiB with 150–300 faults/s for hours, then k3s on that node stalls and the watch cascade takes down the other servers. Compare `sum(container_memory_working_set_bytes{node="<n>",container!=""})` before and after the merge, and where the moved pods ran before.

### Rancher working-set creep
`rancher-limit-thrash-and-kubeversion-gate`

Rancher's working set creeps ~130–150 MiB/day after a restart (11-14 → 11-18: 1.1 → 1.75 GiB). It hits the live 1800Mi limit about 4–5 days after each restart, until the 2Gi limit in git can sync. Track it in the "near their memory limit" section.
