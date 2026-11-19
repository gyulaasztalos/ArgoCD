#!/bin/bash
# =============================================================================
# discover.sh — inspect the cluster kubectl points at and propose cluster.conf
# values plus healthy baselines. READ-ONLY: kubectl get, Prometheus queries,
# and (only if SSH_USER is given) one harmless ssh probe per node.
#
# Usage:  scripts/discover.sh                 # propose config + baselines
#         SSH_USER=ubuntu scripts/discover.sh # also test ssh access per node
#
# It does NOT read cluster.conf — it is meant for a cluster the current config
# does not describe yet. Review the output, then edit cluster.conf (or a
# private copy pointed to by HEALTHCHECK_CONF) by hand. See ADAPTING.md.
#
# Runs on macOS (bash 3.2) and Linux.
# =============================================================================
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"

section()
{
  printf '\n===== %s =====\n' "${1}"
}

echo "Discovering cluster for context: $(kubectl config current-context 2>/dev/null || echo '?')"

# -----------------------------------------------------------------------------
section "NODES"
# -----------------------------------------------------------------------------
kubectl get nodes --no-headers \
  -o custom-columns='NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage,ARCH:.status.nodeInfo.architecture,ALLOCATABLE-MEM:.status.allocatable.memory'
echo "-- control-plane nodes (label node-role.kubernetes.io/control-plane):"
kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
# First InternalIP per node — dual-stack nodes list IPv4 first by convention.
NODES_LINE="$(kubectl get nodes -o json \
  | jq -r '[.items[] | "\(.metadata.name):\([.status.addresses[] | select(.type == "InternalIP") | .address][0])"] | join(" ")')"
NODE_NAMES_RE="$(kubectl get nodes -o json | jq -r '[.items[].metadata.name] | join("|")')"

# -----------------------------------------------------------------------------
section "PROMETHEUS"
# -----------------------------------------------------------------------------
# Candidate: a Service exposing 9090 whose name says prometheus, skipping the
# operator's headless "-operated" service and alertmanager/other helpers.
PROM_CANDIDATE="$(kubectl get svc -A -o json \
  | jq -r '.items[]
           | select(.metadata.name | test("prometheus"))
           | select(.metadata.name | test("operated|alertmanager|operator|node-exporter|kube-state|pushgateway|adapter") | not)
           | select([.spec.ports[].port] | index(9090))
           | "\(.metadata.namespace) \(.metadata.name) 9090"' | head -1)"
if [ -z "${PROM_CANDIDATE}" ]
then
  echo "No Prometheus service on port 9090 found. Set PROM_NAMESPACE/PROM_SERVICE/PROM_PORT by hand."
  PROM_NS=""
else
  # shellcheck disable=SC2086
  set -- ${PROM_CANDIDATE}
  PROM_NS="${1}"
  PROM_SVC="${2}"
  PROM_PORT="${3}"
  PROM_API="/api/v1/namespaces/${PROM_NS}/services/${PROM_SVC}:${PROM_PORT}/proxy/api/v1"
  echo "Found ${PROM_NS}/${PROM_SVC}:${PROM_PORT}"
  if kubectl get --raw "${PROM_API}/query?query=up" >/dev/null 2>&1
  then
    echo "Reachable through the apiserver service proxy: yes"
  else
    echo "Reachable through the apiserver service proxy: NO — check RBAC (services/proxy) or the service name."
    PROM_NS=""
  fi
fi

# "address[:port]" → node name, like lib.sh's names(), but from the discovered nodes.
names()
{
  local SED_ARGS="" ENTRY NAME ADDRESS
  for ENTRY in ${NODES_LINE}
  do
    NAME="${ENTRY%%:*}"
    ADDRESS="$(printf '%s' "${ENTRY#*:}" | sed 's/\./\\./g')"
    SED_ARGS="${SED_ARGS} -e s/${ADDRESS}\(:[0-9][0-9]*\)\{0,1\}/${NAME}/g"
  done
  # SED_ARGS is deliberately unquoted: it is a list of "-e expr" words.
  sed ${SED_ARGS}
}

# Instant query against the discovered Prometheus; prints "labels value".
q()
{
  local ENCODED
  ENCODED="$(jq -rn --arg q "${1}" '$q|@uri')"
  kubectl get --raw "${PROM_API}/query?query=${ENCODED}" \
    | jq -r --arg labels "${2:-}" '.data.result[]
        | (.metric as $m | [$labels | split(",")[] | select(. != "") as $l | "\($l)=\($m[$l] // "-")"] | join(" ")) as $lbl
        | "\($lbl)  \(.value[1] | tonumber | (. * 1000 | round) / 1000)"' \
    | names
}

RETENTION_DAYS=""
NODE_SELECTOR=""
if [ -n "${PROM_NS}" ]
then
  RETENTION="$(kubectl get --raw "${PROM_API}/status/flags" | jq -r '.data["storage.tsdb.retention.time"] // empty')"
  echo "Retention: ${RETENTION:-unknown}"
  case "${RETENTION}" in
    *d) RETENTION_DAYS="${RETENTION%d}" ;;
    *w) RETENTION_DAYS=$(( ${RETENTION%w} * 7 )) ;;
    *h) RETENTION_DAYS=$(( ${RETENTION%h} / 24 )) ;;
  esac

  echo "-- node-exporter targets (node_uname_info instance / nodename) — anything not a cluster node must be filtered out:"
  q 'node_uname_info' instance,nodename
  # A target belongs to the cluster when its instance (without :port) is a
  # node name or node IP, or its nodename is a node name. (nodename alone is
  # not enough: node-exporter run by e.g. Grafana Alloy reports the pod name.)
  NODE_SELECTOR="$(kubectl get --raw "${PROM_API}/query?query=node_uname_info" \
    | jq -r --arg names "${NODE_NAMES_RE}" --arg nodes "${NODES_LINE}" '
        ($nodes | split(" ") | map(split(":") | {(.[0]): true, ((.[1:] | join(":"))): true}) | add) as $known
        | [.data.result[].metric
           | select($known[.instance | sub(":[0-9]+$"; "")] or $known[.nodename // ""])] as $own
        | if ($own | length) == 0 then ""
          elif all($own[]; $known[.instance] and (.instance | test("^(" + $names + ")$"))) then "instance=~\"" + $names + "\""
          else "instance=~\"" + ([$own[].instance | gsub("\\."; "\\\\.")] | join("|")) + "\""
          end')"
  NODE_TARGETS="$(kubectl get --raw "${PROM_API}/query?query=count(node_uname_info)" | jq -r '.data.result[0].value[1] // 0')"
  NODE_COUNT="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  echo "node-exporter targets: ${NODE_TARGETS}, cluster nodes: ${NODE_COUNT} — the selector below keeps only cluster nodes."
fi

# -----------------------------------------------------------------------------
section "COMPONENTS"
# -----------------------------------------------------------------------------
has_crd()
{
  kubectl get crd "${1}" >/dev/null 2>&1
}

ARGO_NS="$(kubectl get applications.argoproj.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
echo "ArgoCD Applications namespace: ${ARGO_NS:-not found}"

CHECK_LONGHORN=0
LH_NS=""
LH_GROUP=""
if has_crd volumes.longhorn.io
then
  CHECK_LONGHORN=1
  LH_NS="$(kubectl get volumes.longhorn.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
  echo "Longhorn: yes (namespace ${LH_NS:-?}). Recurring-job groups → number of volumes:"
  kubectl get volumes.longhorn.io -A -o json \
    | jq -r '[.items[].metadata.labels // {} | keys[] | select(startswith("recurring-job-group.longhorn.io/")) | sub(".*/"; "")]
             | group_by(.) | map("  \(.[0]) \(length)") | .[]'
  LH_GROUP="$(kubectl get volumes.longhorn.io -A -o json \
    | jq -r '[.items[].metadata.labels // {} | keys[] | select(startswith("recurring-job-group.longhorn.io/")) | sub(".*/"; "")]
             | group_by(.) | max_by(length) | .[0] // empty')"
  echo "  Backup recurring jobs (cron):"
  kubectl get recurringjobs.longhorn.io -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.task == "backup") | "  \(.metadata.name) cron=\(.spec.cron) groups=\(.spec.groups | join(","))"'
else
  echo "Longhorn: no"
fi

CHECK_CNPG=0
if has_crd clusters.postgresql.cnpg.io
then
  CHECK_CNPG=1
  echo "CloudNativePG: yes"
else
  echo "CloudNativePG: no"
fi

CHECK_BGP=0
if [ -n "${PROM_NS}" ] && [ -n "$(q 'frrk8s_bgp_session_up')" ]
then
  CHECK_BGP=1
  echo "frr-k8s BGP metrics: yes (sessions now:)"
  q 'frrk8s_bgp_session_up' node,peer
else
  echo "frr-k8s BGP metrics: no"
fi

GIT_BRANCH="$(git -C "${SCRIPT_DIR}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
echo "Git branch the cluster deploys from (origin's default): ${GIT_BRANCH}"

# -----------------------------------------------------------------------------
section "SSH (only when SSH_USER is set)"
# -----------------------------------------------------------------------------
SSH_ENABLED=0
if [ -n "${SSH_USER:-}" ]
then
  SSH_OK=1
  for ENTRY in ${NODES_LINE}
  do
    NAME="${ENTRY%%:*}"
    ADDRESS="${ENTRY#*:}"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${ADDRESS}" 'journalctl -k -n 1 -q --no-pager >/dev/null 2>&1 && echo journal-ok || echo journal-denied' 2>/dev/null | grep -q journal-ok
    then
      echo "${NAME}: ssh + kernel journal OK"
    else
      echo "${NAME}: ssh or journal access FAILED (key, host key, or user not in adm/systemd-journal)"
      SSH_OK=0
    fi
  done
  SSH_ENABLED="${SSH_OK}"
else
  echo "Skipped. Re-run with SSH_USER=<user> to test read-only ssh to every node."
fi

# -----------------------------------------------------------------------------
section "PROPOSED cluster.conf (review before use)"
# -----------------------------------------------------------------------------
if [ -z "${NODE_SELECTOR}" ]
then
  NODE_SELECTOR="instance=~\"${NODE_NAMES_RE}\""
fi
cat <<EOF
NODES="${NODES_LINE}"
NODE_EXPORTER_SELECTOR='${NODE_SELECTOR}'
SSH_ENABLED=${SSH_ENABLED}
SSH_USER="${SSH_USER:-}"
PROM_NAMESPACE="${PROM_NS:-CHANGE_ME}"
PROM_SERVICE="${PROM_SVC:-CHANGE_ME}"
PROM_PORT="${PROM_PORT:-9090}"
PROM_RETENTION_DAYS=${RETENTION_DAYS:-5}
ARGOCD_NAMESPACE="${ARGO_NS:-argocd}"
GIT_BRANCH="${GIT_BRANCH}"
CHECK_LONGHORN=${CHECK_LONGHORN}
LONGHORN_NAMESPACE="${LH_NS:-longhorn-system}"
LONGHORN_BACKUP_GROUP="${LH_GROUP:-default}"
LONGHORN_BACKUP_MAX_AGE_H=26
CHECK_CNPG=${CHECK_CNPG}
CHECK_BGP=${CHECK_BGP}
EOF

# -----------------------------------------------------------------------------
section "BASELINES over the retention window (for references/known-issues.md)"
# -----------------------------------------------------------------------------
# Only meaningful if the retention window was a normal period — if it contains
# an incident, the max column shows the incident, not health. Median ≈ typical.
if [ -n "${PROM_NS}" ]
then
  W="${RETENTION_DAYS:-5}d"
  SEL="${NODE_SELECTOR}"
  echo "-- watches per apiserver: median | max"
  q "quantile_over_time(0.5, sum by (instance)(apiserver_longrunning_requests{job=\"apiserver\"})[${W}:5m])" instance | sed 's/^/median  /'
  q "max_over_time(sum by (instance)(apiserver_longrunning_requests{job=\"apiserver\"})[${W}:5m])" instance | sed 's/^/max     /'
  echo "-- apiserver RSS GiB: median | max"
  q "quantile_over_time(0.5, process_resident_memory_bytes{job=\"apiserver\"}[${W}])/2^30" instance | sed 's/^/median  /'
  q "max_over_time(process_resident_memory_bytes{job=\"apiserver\"}[${W}])/2^30" instance | sed 's/^/max     /'
  echo "-- MemAvailable GiB per node: median | min"
  q "quantile_over_time(0.5, node_memory_MemAvailable_bytes{${SEL}}[${W}])/2^30" instance | sed 's/^/median  /'
  q "min_over_time(node_memory_MemAvailable_bytes{${SEL}}[${W}])/2^30" instance | sed 's/^/min     /'
  echo "-- major page faults/s (10m rate): p95 | max"
  q "quantile_over_time(0.95, rate(node_vmstat_pgmajfault{${SEL}}[10m])[${W}:5m])" instance | sed 's/^/p95     /'
  q "max_over_time(rate(node_vmstat_pgmajfault{${SEL}}[10m])[${W}:5m])" instance | sed 's/^/max     /'
  echo "-- etcd WAL fsync p99 seconds: max (empty = etcd not scraped)"
  q "max_over_time(histogram_quantile(0.99, sum by (instance,le)(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))[${W}:5m])" instance
  echo "-- alerts that fired in the window (candidates for 'accepted noise' — decide each one):"
  q "count by (alertname, namespace) (max_over_time(ALERTS{alertstate=\"firing\"}[${W}]))" alertname,namespace
fi

printf '\n===== DONE =====\n'
