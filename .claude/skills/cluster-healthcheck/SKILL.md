---
name: cluster-healthcheck
description: Read-only health check of the homelab k3s cluster (4× Raspberry Pi 5: archer, lana, pam, cheryl) covering nodes, pods, Renovate merges, ArgoCD sync, alerts, apiserver watch balance and memory, etcd, memory pressure and evictions, containers near their memory limit, scheduling headroom, Longhorn, CNPG, backups, BGP and node kernel logs, then a classified report. Use it whenever the user asks for a healthcheck, cluster check or status ("check the cluster", "healthcheck now", "how's the cluster", "a night passed, check it", "is everything ok after the restart?"). Also use it when an alert fired (KubeAggregatedAPIDown, LonghornNodeDown, NodeMemoryMajorPagesFaults, TargetDown...) and the user wants to know what happened, or to verify a fix after a push, a k3s restart or a Renovate rollout.
---

# Cluster healthcheck

A repeatable, **read-only** health check of the homelab k3s cluster. It gathers the facts
with one script, classifies each finding against known failure modes and accepted noise,
drills into anything new, and reports in a fixed shape. That way consecutive checks can be
compared and a regression stands out.

## Ground rules (why they exist)

- **Read only.** Allowed:
  - `kubectl get / describe / logs`, `kubectl get --raw` for Prometheus
  - `git log` / `git fetch`
  - read-only `ssh red@10.10.50.2x` (journalctl, cat, systemctl show)

  Everything else is a *proposal* that waits for the owner's explicit yes, deleting a single
  pod included. Approval is per action and does not carry over to a different method. This
  is the owner's standing rule (`never-change-cluster-without-consent`).
- **Fixes go into git, never onto live objects.** ArgoCD self-heals within about 2 minutes,
  so a `kubectl patch`, `kubectl edit` or `rollout restart` of an ArgoCD-owned object is
  undone or fights the controller. If a fix can't be expressed in git, stop and report.
  (`never-patch-argocd-owned-resources`)
- **Never commit or push.** Edit, hand back, and suggest a commit message. (`never-commit-or-push`)
- No new comments in `values.yaml` / `application.yaml`; the reasoning goes in the commit message.
- **Architecture choices are the owner's.** Give options with a recommendation; don't pick
  silently.

## Workflow

### 1. Run the battery

```bash
bash .claude/skills/cluster-healthcheck/scripts/healthcheck.sh            # since the previous check
bash .claude/skills/cluster-healthcheck/scripts/healthcheck.sh 3d         # explicit window (max 5d)
```

**Window.** Normally pass nothing. The script records each run's time outside the repo, in
`~/.local/state/cluster-healthcheck/last-run`, and defaults to "since the previous check",
clamped to 1h–5d, with 5d being Prometheus retention. Pass a window only when the user names
one ("the last 3 days") or when you need to look further back than the previous check.

The header prints the previous check's time. Anything before it was already reported then,
so mention it only if it is still unresolved.

It takes about 15 seconds and prints sections for:
- git merges to `origin/main` in the window
- nodes, unhealthy pods, container terminations with reasons, evictions
- containers near their memory limit
- ArgoCD drift
- alerts firing now, plus every alert that fired in the window with its first and last time
- apiserver watches, RSS and restarts (a restart is flagged), etcd
- node memory and major faults
- per-node request headroom, and whether the biggest pods could move
- Longhorn health and backup freshness, CNPG and its backups
- BGP sessions
- macb/OOM lines in each node's kernel log

### 2. Classify every finding

Read `references/known-issues.md`. It has the healthy baselines table, the accepted noise,
and the fingerprints of every failure mode seen so far, each pointing to its memory note.
Put each finding in one bucket:

| Bucket | Treatment |
|---|---|
| Accepted noise | one line in the report, no digging |
| Known failure mode | name it, show the evidence, read its memory note before proposing anything; say whether it still behaves as recorded |
| New or unexplained | drill down (step 3) |

An alert that **fired and resolved** inside the window still counts. The user usually saw
it on their phone, and "it's gone now" is not an explanation.

A breakage that starts shortly after a merge listed in the git section is the first lead.
Read the release notes of whatever was bumped.

### 3. Drill down into anything new

Find the cause, not just the symptom. Useful tools:

- **Timelines:** `scripts/promr.sh '<promql>' <range> <step> [labels] [min]` prints local time. Pass `''` for labels when you only want `min`. Narrow to a 1-minute step around the event.
- **Instant values:** `scripts/promq.sh '<promql>' [labels]`.
- **Why a container died:** `kubectl logs <pod> -c <c> --previous | tail`.
  - `leaderelection lost` means the process stalled (memory or CPU) or the apiserver was slow.
  - `OOMKilled` means the limit was hit.
- **Which cgroup thrashed:**
  ```promql
  topk(8, sum by (namespace,pod)(increase(container_memory_failures_total{node="<n>",failure_type="pgmajfault",scope="container"}[4m])))
  ```
  A pod at its own limit thrashes even when the node has plenty free.
- **Node level:** MemAvailable, `rate(node_vmstat_pgmajfault[2m])`, CPU busy, `etcd_disk_wal_fsync_duration_seconds`, apiserver watches. Line these up by minute to tell node pressure, a single container, and a control-plane problem apart.
- **Rendering a chart to check a fix:** do it in the scratchpad, never in the repo (`kustomize-render-outside-repo`).

**Shell pitfalls.** The user's shell is zsh, which treats `[0]` and `*` in unquoted
arguments as globs. Always single-quote jsonpath, custom-columns and PromQL arguments.
macOS has bash 3.2 and BSD `date` (`date -r <epoch>`, no `date -d`). `git log --since` needs
`"N hours ago"`, not `24h`.

**Time zones trip this up.** These are in UTC:
- alert `activeAt`
- container `startedAt` / `finishedAt`
- the `[...]Z` timestamps in logs

`promr.sh`, the alert-history list and `date` print local time (Europe/Budapest). Convert
before you correlate.

### 4. Report

Use this shape every time, so one check can be compared with the last:

```
<one-sentence verdict: healthy / degraded / incident, and the headline cause if any>
Window: <from> → now (<since previous check | as asked>); merges in window: <short list or none>

| Metric | Now | Worst in window | Healthy |
|---|---|---|---|
| Watches per apiserver (lana/pam/cheryl) | … | … | 500–1,100 |
| apiserver RSS (lana/pam/cheryl) | … | … | 2.0–2.8 GiB |
| MemAvailable (lowest node) | … | … | >1.2 GiB |
| Major faults/s (highest node) | … | … | <100 |
| etcd leaders / changes | … | … | 1 / 0 |
| k3s restarts in window | … | | none |

New findings      – what, when (local time), evidence, cause (or "cause unknown, next step: …")
Known issues      – name → memory note; still behaving as recorded? any trend (e.g. creep toward a limit)?
Accepted noise    – one line listing them
Proposed actions  – each one concrete (git edit or exact command), waiting for a yes
Next check        – when, and what it should confirm
```

Leave out empty sections. When everything is healthy, say so plainly in the verdict and
keep the report short; don't pad it.

### 5. Memory: notable findings only

Write or update a memory note only when the check taught something durable:
- a new failure mode and its fingerprint
- the measured effect of a fix, confirmed or refuted
- a trend with a forecast
- a baseline that has shifted
- a decision the owner made about a finding (for example "ignore X")

A clean run writes nothing. Prefer updating the existing note for that failure mode over
creating a new one, and keep its `MEMORY.md` index line accurate. **Mark every time you
write with its zone** ("14:47 CET", "13:48Z"), because notes and Kubernetes timestamps mix
local time and UTC.

When a baseline or an accepted-noise item changes for good, also update
`references/known-issues.md` so the next run classifies it correctly. It is a file in the
repo, so the owner commits it.

## Cluster facts the battery relies on

- Nodes: archer `10.10.50.21` (agent, unit `k3s-node`); lana `.22`, pam `.23` and cheryl `.24` (servers with embedded etcd, unit `k3s`).
- Prometheus is reached through the apiserver service proxy; no port-forward is needed. Retention is 5d.
- The node-exporter scrape set includes an external Pi (`raspberrypi.local…`) that is not part of the cluster. Always filter with `instance=~"archer|lana|pam|cheryl"`.
- Shell scripts follow the owner's style (`shell-script-style`): UPPERCASE braced vars, `then`/`do` on their own line, generous comments.
