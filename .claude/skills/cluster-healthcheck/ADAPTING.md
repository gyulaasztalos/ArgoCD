# Adapting cluster-healthcheck to your own cluster

This skill was built for one specific homelab: 4× Raspberry Pi 5, k3s with embedded etcd,
Longhorn, CloudNativePG, MetalLB/frr-k8s, ArgoCD and kube-prometheus-stack. If you forked
this repository and run it on your own cluster, with other hostnames, addresses and
hardware, follow this guide once. Afterwards the skill checks *your* cluster against
*your* baselines.

Budget about 30 minutes. Everything here is read-only against the cluster.

## What is portable and what is site-specific

| Part | Portable? | What to do |
|---|---|---|
| `scripts/healthcheck.sh`, `promq.sh`, `promr.sh`, `lib.sh` | yes: no hostnames, addresses or namespaces inside | nothing |
| `scripts/discover.sh` | yes | run it (step 2) |
| `cluster.conf` | **no**: nodes, addresses, ssh user, Prometheus service, optional components, hint thresholds | replace (step 3) |
| `references/known-issues.md` | **partly**: baselines and accepted noise are this cluster's, but several failure modes are generic | re-baseline and prune (step 5) |
| `SKILL.md` | **mostly**: the workflow is generic, while the description and ground rules carry the original owner's setup | small edits (step 6) |

## Prerequisites

The skill needs the following.

**On the machine running it:**
- `kubectl` with a context for the cluster
- `jq`, `git`, and bash (macOS bash 3.2 and Linux bash 4+ both work)

**In the cluster:**
- Prometheus reachable through the apiserver service proxy, i.e. RBAC that allows `services/proxy` in Prometheus' namespace. kube-prometheus-stack defaults work.
- These metrics:
  - node-exporter (`node_memory_MemAvailable_bytes`, `node_vmstat_pgmajfault`, `node_vmstat_oom_kill`, `node_uname_info`)
  - kube-state-metrics (`kube_pod_container_resource_limits`)
  - cAdvisor (`container_memory_working_set_bytes`)
  - the apiserver scrape job named `apiserver`, with `apiserver_longrunning_requests` and `process_resident_memory_bytes`
  - etcd metrics, optional (`etcd_server_is_leader`, `etcd_disk_wal_fsync_duration_seconds_bucket`)

  Managed control planes (EKS, GKE, AKS) don't expose apiserver process memory or etcd, so those lines stay empty there. Everything else still works.
- ArgoCD, optional: without it the ArgoCD section is simply empty.

**Optional:** read-only ssh to every node, by a user who can read the kernel journal (the
`adm` or `systemd-journal` group). This enables the kernel-log section; without it, set
`SSH_ENABLED=0`.

## Step 1: point kubectl at your cluster

```bash
kubectl config current-context    # must be YOUR cluster
kubectl get nodes
```

The battery keeps its "previous check" timestamp per kube context. Several clusters
therefore don't mix, but the context name should stay stable.

## Step 2: discover

```bash
SSH_USER=<your-node-user> .claude/skills/cluster-healthcheck/scripts/discover.sh
```

Leave out `SSH_USER` if you won't use ssh. `discover.sh` prints:

- **Nodes** with their InternalIP, and which are control-plane nodes.
- **Prometheus:** the service it found, whether the proxy path works, and the retention.
- **node-exporter targets,** and a selector that keeps only *cluster* nodes. Many setups also scrape machines outside the cluster; this one scrapes an external Pi. Check the reasoning:
  - When `instance` is the node name, it selects by name.
  - When `instance` is `<ip>:9100`, it selects by those instances.
  - It does not trust `nodename`, because node-exporter run by Grafana Alloy reports the pod name there.
- **Components:** ArgoCD namespace, Longhorn (namespace, recurring-job groups, backup cron), CloudNativePG, frr-k8s BGP metrics, and the git branch.
- **ssh:** per-node ssh and journal access, when `SSH_USER` was given.
- **A proposed `cluster.conf` block.**
- **Baselines over the retention window,** plus every alert that fired in it.

Nothing is written. Review the output; it is a proposal.

## Step 3: write your config

You have two options:

- **Edit `cluster.conf` in your fork.** Simplest if your fork won't track upstream closely.
- **Keep a private copy and point the skill at it.** Better if you keep pulling from upstream, because it avoids merge conflicts in `cluster.conf`:

  ```bash
  cp .claude/skills/cluster-healthcheck/cluster.conf ~/.config/cluster-healthcheck.conf
  # edit it, then export it in your shell profile:
  export HEALTHCHECK_CONF=~/.config/cluster-healthcheck.conf
  ```

  Claude Code passes the environment through, so the skill picks it up.

Then:

1. Paste the proposed block from `discover.sh` over the matching lines.
2. **Fix `NODES` if needed.** Node names must equal the Kubernetes node names. Addresses
   are used for ssh and to turn `address:port` metric instances into names. On dual-stack
   nodes, pick the address family your apiserver and etcd metrics use (usually IPv4).
3. **Set the `HINT_*` lines** from the baselines output (step 5 explains how to read it),
   or leave them empty until you have baselines.
4. **Set `LONGHORN_BACKUP_MAX_AGE_H`** to your backup interval plus a margin: daily → 26,
   hourly → 2.

## Step 4: verify

```bash
.claude/skills/cluster-healthcheck/scripts/healthcheck.sh 2h
```

Check that:
- [ ] There is **no `WARNING: cluster.conf nodes … differ`** line at the top.
- [ ] Control-plane sections show **node names**, not IPs. If you see IPs, `NODES` addresses don't match the metric instances.
- [ ] Node memory sections list **exactly your nodes**: none missing, nothing extra. If not, fix `NODE_EXPORTER_SELECTOR`.
- [ ] Sections for components you disabled say `(skipped: …)`, and enabled ones have content.
- [ ] The kernel-log section shows counts, not `ssh failed`, if ssh is enabled.

## Step 5: re-baseline `references/known-issues.md`

This file is what turns raw numbers into a verdict, so it has to describe *your* cluster.

**Baselines table.**
- Take the numbers from a **quiet period**. `discover.sh` uses the whole retention window; if an incident happened in it, its max/min columns show the incident.
- Rule of thumb:
  - *healthy* = the median ± normal spread
  - *warning* = clearly outside anything seen on a calm day
  - *incident* = what you have actually seen go wrong (leave it empty until you have)
- Hardware matters. An 8 GB Pi and a 64 GB server have very different MemAvailable and apiserver RSS, so never keep the original numbers.

**Accepted noise.**
- Delete the original owner's entries; they describe their alerts.
- Go through the "alerts that fired" list from `discover.sh`. For each alert that is *known and deliberately tolerated*, add an entry with the reason.
- Everything else stays a finding. A short, honest noise list is the point: anything on it gets skipped.

**Failure modes.**

| Keep (generic) | Drop or replace if you lack the hardware/setup |
|---|---|
| Control-plane watch imbalance (any multi-server control plane behind a VIP or load balancer) | Rancher hits its own memory limit (Rancher only) |
| A container thrashing at its own memory limit | Longhorn strict-local phantom replica (Longhorn) |
| Kubelet eviction ranking hitting the wrong pod | frr-k8s BGP not self-healing (frr-k8s) |
| Pending pod from fragmentation | Pi 5 macb TX-queue hang (Raspberry Pi 5 NIC) |
| Native sidecars missing from request sums | NFS backup target hung (NFS backup target) |
| A dependency-bot auto-merge breaking an app | k3s auto-upgrade surprises (k3s system-upgrade-controller) |

**Memory slugs.** The original notes point to the owner's private Claude memory (names like
`control-plane-swap-thrash-follows-watches`). You don't have those notes. Remove the slug
references, or replace them with links to your own docs or memory. They are pointers only;
the fingerprints are written out in full in the file.

## Step 6: edit `SKILL.md`

- **`description` (frontmatter)** decides when Claude loads the skill. Replace
  "4× Raspberry Pi 5: archer, lana, pam, cheryl" with a short description of your cluster,
  and keep the trigger phrases.
- **Ground rules** carry the original owner's working agreement: read-only, fixes via git
  only, never commit or push, no comments in values files. The read-only rule is what makes
  the skill safe to run anytime, so keep it. Adjust the rest to how you work.
- **Cluster facts** at the bottom: nothing site-specific should remain there besides a
  pointer to `cluster.conf`. Check that it still holds after your edits.
- **Memory step (5):** it assumes Claude Code's auto-memory. If you don't use it, drop the
  step or point it at your own notes.

## Step 7: first real run

Ask Claude: *"healthcheck the cluster"*. On the first run, expect it to flag things you
consider normal. Each time, decide whether it is accepted noise (add it to
`known-issues.md` with the reason) or a real problem (fix it). After two or three runs the
classification settles down.

## Keeping it adapted

- Re-run `discover.sh` after adding or removing nodes, changing the monitoring stack, or
  installing or removing Longhorn, CNPG or frr-k8s. The battery's node-mismatch warning
  reminds you when `cluster.conf` has gone stale.
- Re-baseline after hardware changes or big workload changes. The baselines are only
  as good as the period they came from.
