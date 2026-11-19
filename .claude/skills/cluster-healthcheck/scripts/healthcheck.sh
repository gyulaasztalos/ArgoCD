#!/bin/bash
# =============================================================================
# healthcheck.sh — read-only health battery for the homelab k3s cluster.
#
# Usage:  healthcheck.sh [window]
#
#   window  how far back to look: 90m, 24h, 3d (max = Prometheus retention).
#           Omitted → "since the previous run" (read from the state file below),
#           clamped to 1h..retention; 24h when there is no previous run.
#
# All cluster-specific values (nodes, addresses, Prometheus service, optional
# components) come from ../cluster.conf — see ../ADAPTING.md to point the skill
# at another cluster.
#
# Runs every standard check and prints labelled sections. It only READS:
# kubectl get/logs, Prometheus queries, git log, and read-only journalctl over
# ssh. The one thing it writes is its own last-run timestamp (outside the repo).
# Interpretation is done by the caller with SKILL.md + references/known-issues.md.
#
# Runs on macOS (bash 3.2, BSD userland) and Linux (bash 4+, GNU userland).
# =============================================================================
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
# lib.sh loads cluster.conf (or ${HEALTHCHECK_CONF}) and the portable helpers:
# to_seconds, fmt_epoch, names, node_names_regex, PROM_API.
. "${SCRIPT_DIR}/lib.sh"
REPO_DIR="$(git -C "${SKILL_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SKILL_DIR}")"
PROMQ="${SCRIPT_DIR}/promq.sh"
PROMR="${SCRIPT_DIR}/promr.sh"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/cluster-healthcheck"
# One state file per kube context, so checks of different clusters don't mix.
CONTEXT="$(kubectl config current-context 2>/dev/null || echo default)"
STATE_FILE="${STATE_DIR}/last-run-$(printf '%s' "${CONTEXT}" | tr -c 'A-Za-z0-9._-' '_')"
NOW="$(date +%s)"
NODE_RE="${NODE_EXPORTER_SELECTOR:-instance=~\"$(node_names_regex)\"}"
MAX_WINDOW_S=$(( PROM_RETENTION_DAYS * 86400 ))

section()
{
  printf '\n===== %s =====\n' "${1}"
}

# -----------------------------------------------------------------------------
# Window selection
# -----------------------------------------------------------------------------
PREVIOUS_RUN=""
if [ -r "${STATE_FILE}" ]
then
  PREVIOUS_RUN="$(cat "${STATE_FILE}")"
fi

if [ -n "${1:-}" ]
then
  WINDOW_S="$(to_seconds "${1}")"
  WINDOW_SOURCE="given"
elif [ -n "${PREVIOUS_RUN}" ]
then
  WINDOW_S=$(( NOW - PREVIOUS_RUN ))
  WINDOW_SOURCE="since previous run"
else
  WINDOW_S=86400
  WINDOW_SOURCE="default, no previous run recorded"
fi
# Clamp to 1h..retention: shorter windows miss the rate() context, longer ones
# ask Prometheus for data it no longer has.
if [ "${WINDOW_S}" -lt 3600 ]
then
  WINDOW_S=3600
fi
if [ "${WINDOW_S}" -gt "${MAX_WINDOW_S}" ]
then
  WINDOW_S="${MAX_WINDOW_S}"
fi
WINDOW="${WINDOW_S}s"
WINDOW_H=$(( (WINDOW_S + 3599) / 3600 ))
SINCE_EPOCH=$(( NOW - WINDOW_S ))

printf 'Cluster healthcheck — %s — context %s\n' "$(fmt_epoch "${NOW}" '%Y-%m-%d %H:%M %Z')" "${CONTEXT}"
printf 'Window: %sh (%s), from %s\n' "${WINDOW_H}" "${WINDOW_SOURCE}" "$(fmt_epoch "${SINCE_EPOCH}" '%m-%d %H:%M')"
if [ -n "${PREVIOUS_RUN}" ]
then
  printf 'Previous check: %s — events before it were already reported then.\n' "$(fmt_epoch "${PREVIOUS_RUN}" '%Y-%m-%d %H:%M')"
fi

# Does cluster.conf describe the cluster kubectl points at? A mismatch means
# the skill was copied to another cluster without adapting it (ADAPTING.md).
CONF_NODES="$(for ENTRY in ${NODES}; do echo "${ENTRY%%:*}"; done | sort | paste -sd' ' -)"
LIVE_NODES="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort | paste -sd' ' -)"
if [ "${CONF_NODES}" != "${LIVE_NODES}" ]
then
  echo "WARNING: cluster.conf nodes (${CONF_NODES}) differ from the live cluster (${LIVE_NODES})."
  echo "         Node-level sections may be empty or wrong. Run scripts/discover.sh and follow ADAPTING.md."
fi

# -----------------------------------------------------------------------------
section "GIT — merges to ${GIT_BRANCH} in window (dependency bots are the usual trigger)"
# -----------------------------------------------------------------------------
# NOTE: git's --since does NOT understand "24h"/"5d"; it needs "N seconds ago".
git -C "${REPO_DIR}" fetch -q 2>/dev/null || echo "(git fetch failed — showing the local copy of ${GIT_BRANCH})"
git -C "${REPO_DIR}" log --since="${WINDOW_S} seconds ago" --format='%cd %h %s' --date=format-local:'%m-%d %H:%M' "${GIT_BRANCH}"

# -----------------------------------------------------------------------------
section "NODES"
# -----------------------------------------------------------------------------
kubectl get nodes --no-headers \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,VERSION:.status.nodeInfo.kubeletVersion,UNSCHEDULABLE:.spec.unschedulable'
echo "-- pressure / problem conditions (EtcdIsVoter is informational and filtered out):"
kubectl get nodes -o json \
  | jq -r '.items[] | .metadata.name as $n | .status.conditions[]
           | select(.type != "Ready" and .type != "EtcdIsVoter" and .status == "True")
           | "\($n) \(.type) since \(.lastTransitionTime)"'

# -----------------------------------------------------------------------------
section "PODS NOT HEALTHY"
# -----------------------------------------------------------------------------
kubectl get pods -A -o json \
  | jq -r '.items[]
           | select(.status.phase != "Succeeded")
           | select(
               .status.phase != "Running"
               or ([.status.containerStatuses[]? | select(.ready | not)] | length > 0))
           | "\(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase) node=\(.spec.nodeName // "-") "
             + ([.status.containerStatuses[]? | select(.ready | not)
                 | "\(.name):\(.state | keys[0])\(if .state.waiting then "(" + (.state.waiting.reason // "") + ")" else "" end)"]
                | join(","))'

# -----------------------------------------------------------------------------
section "CONTAINER TERMINATIONS IN WINDOW (UTC timestamps)"
# -----------------------------------------------------------------------------
# lastState.terminated tells WHY: OOMKilled (limit hit), Error (often
# "leaderelection lost" — read logs --previous), Completed (probe kill).
kubectl get pods -A -o json \
  | jq -r --argjson since "${SINCE_EPOCH}" '.items[] | .metadata.namespace as $ns | .metadata.name as $p | .spec.nodeName as $node
           | (.status.containerStatuses // [])[]
           | select(.lastState.terminated != null)
           | select((.lastState.terminated.finishedAt | fromdateiso8601) > $since)
           | "\(.lastState.terminated.finishedAt) \($ns)/\($p) [\(.name)] node=\($node) reason=\(.lastState.terminated.reason) exit=\(.lastState.terminated.exitCode) restarts=\(.restartCount)"' \
  | sort
echo "-- evicted / OOM / preempted events still in the event store:"
kubectl get events -A -o json \
  | jq -r '.items[] | select(.reason == "Evicted" or .reason == "OOMKilling" or .reason == "SystemOOM" or .reason == "Preempted")
           | "\(.lastTimestamp // .eventTime) \(.involvedObject.namespace)/\(.involvedObject.name) \(.reason): \(.message | .[0:160])"'

# -----------------------------------------------------------------------------
section "CONTAINERS NEAR THEIR MEMORY LIMIT (max working set / limit over window > 85%)"
# -----------------------------------------------------------------------------
# A container pinned near its own limit thrashes its page cache (major
# faults, stalls, lost leases) long before an OOM kill — this predicts it.
"${PROMQ}" "sort_desc(max_over_time((max by (namespace,pod,container)(container_memory_working_set_bytes{container!=\"\",container!=\"POD\"}) / on (namespace,pod,container) group_left max by (namespace,pod,container)(kube_pod_container_resource_limits{resource=\"memory\"}))[${WINDOW}:5m]) > 0.85)" namespace,pod,container
echo "-- the same containers now (ratio):"
"${PROMQ}" "sort_desc((max by (namespace,pod,container)(container_memory_working_set_bytes{container!=\"\",container!=\"POD\"}) / on (namespace,pod,container) group_left max by (namespace,pod,container)(kube_pod_container_resource_limits{resource=\"memory\"})) > 0.75)" namespace,pod,container

# -----------------------------------------------------------------------------
section "ARGOCD APPS NOT Synced/Healthy"
# -----------------------------------------------------------------------------
kubectl get applications -n "${ARGOCD_NAMESPACE}" -o json \
  | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
           | "\(.metadata.name) sync=\(.status.sync.status) health=\(.status.health.status) "
             + ((.status.conditions // [])[0].message // "" | .[0:200])'

# -----------------------------------------------------------------------------
section "ALERTS"
# -----------------------------------------------------------------------------
echo "-- firing/pending now (activeAt in UTC):"
kubectl get --raw "${PROM_API}/alerts" \
  | jq -r '.data.alerts[]
           | "\(.activeAt[0:16]) \(.state) \(.labels.alertname) "
             + ([.labels | to_entries[]
                 | select(.key | IN("namespace","pod","name","job","node","instance","persistentvolumeclaim","statefulset","deployment","container","severity"))
                 | "\(.key)=\(.value)"] | join(" "))' \
  | sort
echo "-- every alert that fired in the window: first..last firing sample (local time), minutes firing:"
ENCODED="$(jq -rn --arg q 'max by (alertname, namespace, name, pod, instance)(ALERTS{alertstate="firing"})' '$q|@uri')"
# Step keeps the series under Prometheus' 11k-points limit for a 5d window.
STEP=$(( WINDOW_S / 2000 ))
if [ "${STEP}" -lt 60 ]
then
  STEP=60
fi
kubectl get --raw "${PROM_API}/query_range?query=${ENCODED}&start=${SINCE_EPOCH}&end=${NOW}&step=${STEP}" \
  | jq -r --argjson step "${STEP}" '.data.result[]
           | (.metric | [to_entries[] | select(.value != "") | "\(.key)=\(.value)"] | join(" ")) as $lbl
           | (.values | map(.[0])) as $t
           | "\($t[0] | localtime | strftime("%m-%d %H:%M"))..\($t[-1] | localtime | strftime("%m-%d %H:%M")) (\(($t | length) * $step / 60 | floor)m) \($lbl)"' \
  | sort | names

# -----------------------------------------------------------------------------
section "CONTROL PLANE — apiserver watches / memory / uptime, etcd"
# -----------------------------------------------------------------------------
echo "-- watches per apiserver: now | max in window   ${HINT_WATCHES:+(${HINT_WATCHES})}"
"${PROMQ}" 'sum by (instance)(apiserver_longrunning_requests{job="apiserver"})' instance | names | sed 's/^/now   /'
"${PROMQ}" "max_over_time(sum by (instance)(apiserver_longrunning_requests{job=\"apiserver\"})[${WINDOW}:5m])" instance | names | sed 's/^/max   /'
echo "-- apiserver RSS GiB: now | max in window   ${HINT_APISERVER_RSS:+(${HINT_APISERVER_RSS})}"
"${PROMQ}" 'process_resident_memory_bytes{job="apiserver"}/2^30' instance | names | sed 's/^/now   /'
"${PROMQ}" "max_over_time(process_resident_memory_bytes{job=\"apiserver\"}[${WINDOW}])/2^30" instance | names | sed 's/^/max   /'
echo "-- apiserver process start (local) — inside the window = k3s restarted:"
"${PROMQ}" 'process_start_time_seconds{job="apiserver"}' instance \
  | names \
  | while read -r INSTANCE VALUE
    do
      FLAG=""
      if [ "${VALUE%.*}" -gt "${SINCE_EPOCH}" ]
      then
        FLAG="   <-- RESTARTED IN WINDOW"
      fi
      echo "${INSTANCE} started $(fmt_epoch "${VALUE%.*}" '%Y-%m-%d %H:%M')${FLAG}"
    done
echo "-- etcd leaders now (must be exactly 1):"
"${PROMQ}" 'count(etcd_server_is_leader == 1)'
echo "-- etcd leader changes in window (every member counts the same change):"
"${PROMQ}" "increase(etcd_server_leader_changes_seen_total[${WINDOW}])" instance | names
echo "-- etcd WAL fsync p99 seconds, max in window   ${HINT_ETCD_FSYNC:+(${HINT_ETCD_FSYNC})}"
"${PROMQ}" "max_over_time(histogram_quantile(0.99, sum by (instance,le)(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))[${WINDOW}:5m])" instance | names

# -----------------------------------------------------------------------------
section "NODE MEMORY PRESSURE"
# -----------------------------------------------------------------------------
echo "-- MemAvailable GiB: now | min in window   ${HINT_MEMAVAILABLE:+(${HINT_MEMAVAILABLE})}"
"${PROMQ}" "node_memory_MemAvailable_bytes{${NODE_RE}}/2^30" instance | sed 's/^/now   /'
"${PROMQ}" "min_over_time(node_memory_MemAvailable_bytes{${NODE_RE}}[${WINDOW}])/2^30" instance | sed 's/^/min   /'
echo "-- major page faults/s (10m rate): now | max in window   ${HINT_MAJFAULT:+(${HINT_MAJFAULT})}"
"${PROMQ}" "rate(node_vmstat_pgmajfault{${NODE_RE}}[10m])" instance | sed 's/^/now   /'
"${PROMQ}" "max_over_time(rate(node_vmstat_pgmajfault{${NODE_RE}}[10m])[${WINDOW}:5m])" instance | sed 's/^/max   /'
echo "-- moments with >${MAJFAULT_THRESHOLD} major faults/s (local time; empty = none):"
"${PROMR}" "rate(node_vmstat_pgmajfault{${NODE_RE}}[10m])" "${WINDOW}" 5m instance "${MAJFAULT_THRESHOLD}"
echo "-- kernel OOM kills in window:"
"${PROMQ}" "increase(node_vmstat_oom_kill{${NODE_RE}}[${WINDOW}])" instance

# -----------------------------------------------------------------------------
section "SCHEDULING HEADROOM (allocatable − requests, incl. native sidecars)"
# -----------------------------------------------------------------------------
# A pod that has to move (eviction, rollout surge, node drain) needs its full
# request free on ANOTHER node; cluster-wide free memory is not enough.
# Native sidecars (initContainers with restartPolicy Always) count.
PODS_JSON="${TMPDIR:-/tmp}/hc-pods.$$.json"
NODES_JSON="${TMPDIR:-/tmp}/hc-nodes.$$.json"
kubectl get pods -A --field-selector=status.phase=Running -o json > "${PODS_JSON}"
kubectl get nodes -o json > "${NODES_JSON}"
jq -r --slurpfile pods "${PODS_JSON}" '
    def mib: if . == null then 0
             elif test("Ki$") then (.[:-2] | tonumber / 1024)
             elif test("Mi$") then (.[:-2] | tonumber)
             elif test("Gi$") then (.[:-2] | tonumber * 1024)
             elif test("k$")  then (.[:-1] | tonumber * 1000 / 1048576)
             elif test("M$")  then (.[:-1] | tonumber * 1000000 / 1048576)
             elif test("G$")  then (.[:-1] | tonumber * 1000000000 / 1048576)
             else (tonumber / 1048576) end;
    def podreq: ([.spec.containers[].resources.requests.memory | mib]
                 + [(.spec.initContainers // [])[] | select(.restartPolicy == "Always") | .resources.requests.memory | mib])
                | add;
    [.items[] | .metadata.name as $n
     | (.status.allocatable.memory | mib) as $alloc
     | ([$pods[0].items[] | select(.spec.nodeName == $n) | podreq] | add) as $req
     | {n: $n, alloc: $alloc, req: $req, free: ($alloc - $req)}] as $nodes
    | ($nodes[] | "\(.n) allocatable=\(.alloc | floor)Mi requested=\(.req | floor)Mi free=\(.free | floor)Mi"),
      "-- largest pods: could each be rescheduled onto ANOTHER node right now?",
      ([$pods[0].items[] | {p: "\(.metadata.namespace)/\(.metadata.name)", n: .spec.nodeName, r: podreq}]
       | sort_by(-.r) | .[0:4][]
       | . as $pod
       | ([$nodes[] | select(.n != $pod.n) | .free] | max) as $best
       | "\($pod.r | floor)Mi \($pod.p) on \($pod.n): best other node has \($best | floor)Mi free → "
         + (if $best >= $pod.r then "OK" else "WOULD NOT FIT (stays Pending if it has to move)" end))
  ' "${NODES_JSON}"
rm -f "${PODS_JSON}" "${NODES_JSON}"

# -----------------------------------------------------------------------------
section "STORAGE — Longhorn, CNPG, backups"
# -----------------------------------------------------------------------------
if [ "${CHECK_LONGHORN}" != "1" ] && [ "${CHECK_CNPG}" != "1" ]
then
  echo "(skipped: CHECK_LONGHORN=0, CHECK_CNPG=0)"
fi
if [ "${CHECK_LONGHORN}" = "1" ]
then
  echo "-- Longhorn volume robustness counts:"
  kubectl get volumes.longhorn.io -n "${LONGHORN_NAMESPACE}" -o json \
    | jq -r '[.items[] | .status.robustness] | group_by(.) | map("\(.[0])=\(length)") | join(" ")'
  kubectl get volumes.longhorn.io -n "${LONGHORN_NAMESPACE}" -o json \
    | jq -r '.items[] | select(.status.robustness != "healthy" and .status.state == "attached")
             | "  NOT HEALTHY: \(.metadata.name) pvc=\(.status.kubernetesStatus.namespace)/\(.status.kubernetesStatus.pvcName) robustness=\(.status.robustness)"'
  echo "-- Longhorn backups: volumes in recurring group '${LONGHORN_BACKUP_GROUP}' whose last backup is older than ${LONGHORN_BACKUP_MAX_AGE_H}h:"
  kubectl get volumes.longhorn.io -n "${LONGHORN_NAMESPACE}" -o json \
    | jq -r --argjson now "${NOW}" --arg group "recurring-job-group.longhorn.io/${LONGHORN_BACKUP_GROUP}" --argjson maxage "$(( LONGHORN_BACKUP_MAX_AGE_H * 3600 ))" '
        [.items[] | select(.metadata.labels[$group] != null)] as $v
        | "  \($v | length) volumes in group \($group | sub(".*/"; "")); newest-oldest lastBackupAt: \([$v[].status.lastBackupAt] | sort | .[0]) .. \([$v[].status.lastBackupAt] | sort | .[-1])",
          ($v[] | select((.status.lastBackupAt // "") == "" or ($now - (.status.lastBackupAt | fromdateiso8601)) > $maxage)
           | "  STALE: \(.metadata.name) pvc=\(.status.kubernetesStatus.namespace)/\(.status.kubernetesStatus.pvcName) lastBackupAt=\(.status.lastBackupAt)")'
  echo "-- Longhorn backup objects not Completed:"
  kubectl get backups.longhorn.io -n "${LONGHORN_NAMESPACE}" -o json \
    | jq -r '.items[] | select(.status.state != "Completed" and .status.state != "")
             | "  \(.metadata.name) state=\(.status.state) volume=\(.status.volumeName) \(.status.error // "" | .[0:160])"'
  echo "-- Longhorn instance-manager priority class (system-node-critical/-cluster-critical = never evicted by kubelet):"
  kubectl get pods -n "${LONGHORN_NAMESPACE}" -l longhorn.io/component=instance-manager --no-headers \
    -o custom-columns='NODE:.spec.nodeName,PRIORITY:.spec.priorityClassName,CREATED:.metadata.creationTimestamp'
fi
if [ "${CHECK_CNPG}" = "1" ]
then
  echo "-- CNPG clusters:"
  kubectl get clusters.postgresql.cnpg.io -A --no-headers \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyInstances,INSTANCES:.status.instances,PHASE:.status.phase,PRIMARY:.status.currentPrimary'
  echo "-- CNPG last backups (hourly):"
  kubectl get backups.postgresql.cnpg.io -A --sort-by=.metadata.creationTimestamp --no-headers \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,STOPPED:.status.stoppedAt' | tail -3
  echo "-- CNPG replication lag seconds:"
  "${PROMQ}" 'max by (pod)(cnpg_pg_replication_lag)' pod
fi

# -----------------------------------------------------------------------------
section "NETWORK — BGP sessions (frr-k8s; 1 = up)"
# -----------------------------------------------------------------------------
if [ "${CHECK_BGP}" = "1" ]
then
  "${PROMQ}" 'frrk8s_bgp_session_up' node,peer
else
  echo "(skipped: CHECK_BGP=0)"
fi

# -----------------------------------------------------------------------------
section "NODE KERNEL LOG (last ${WINDOW_H}h via ssh, read-only)"
# -----------------------------------------------------------------------------
# macb TX-queue hangs and OOMs leave fingerprints here that Prometheus misses
# when the node was unreachable at the time.
if [ "${SSH_ENABLED}" = "1" ]
then
  for ENTRY in ${NODES}
  do
    NAME="${ENTRY%%:*}"
    IP="${ENTRY#*:}"
    RESULT="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${IP}" \
      "journalctl -k --since '-${WINDOW_H}h' -q --no-pager 2>/dev/null | grep -cE 'NETDEV WATCHDOG|transmit queue .* timed out'; journalctl -k --since '-${WINDOW_H}h' -q --no-pager 2>/dev/null | grep -cE 'Out of memory|oom-kill'" 2>/dev/null | paste -sd' ' -)"
    if [ -n "${RESULT}" ]
    then
      echo "${NAME}: macb-tx-timeouts oom-lines = ${RESULT}"
    else
      echo "${NAME}: ssh failed (node unreachable or key missing)"
    fi
  done
else
  echo "(skipped: SSH_ENABLED=0)"
fi

# Record this run so the next one defaults to "since previous check".
mkdir -p "${STATE_DIR}" && echo "${NOW}" > "${STATE_FILE}"

printf '\n===== DONE =====\n'
