# Known issues, fingerprints and accepted noise

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

Renovate's `automergeSchedule` is *meant* to allow weekdays 05:00–16:00 plus weekends (Europe/Budapest). As of 11-19, though, `renovate.json` lists "after 5am every weekday" and "before 4pm every weekday" as separate entries, and Renovate ORs them, so merges also land on weekday evenings (for example 22:04). Don't rule out a merge as a trigger because of its time of day.

### Rancher working-set creep
`rancher-limit-thrash-and-kubeversion-gate`

Rancher's working set creeps ~130–150 MiB/day after a restart (11-14 → 11-18: 1.1 → 1.75 GiB). It hits the live 1800Mi limit about 4–5 days after each restart, until the 2Gi limit in git can sync. Track it in the "near their memory limit" section.
