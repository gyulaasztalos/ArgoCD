#!/bin/bash
# =============================================================================
# lib.sh — shared setup for the healthcheck scripts (source it, don't run it).
#
# Loads cluster.conf (or ${HEALTHCHECK_CONF}) and defines helpers that behave
# the same on macOS (bash 3.2, BSD date) and Linux (GNU date).
# =============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${LIB_DIR}/.." && pwd)"
CONF_FILE="${HEALTHCHECK_CONF:-${SKILL_DIR}/cluster.conf}"

if [ ! -r "${CONF_FILE}" ]
then
  echo "healthcheck: config not found: ${CONF_FILE} (see ADAPTING.md)" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${CONF_FILE}"

# Defaults for anything an older or minimal config leaves out.
PROM_NAMESPACE="${PROM_NAMESPACE:-monitoring}"
PROM_PORT="${PROM_PORT:-9090}"
PROM_RETENTION_DAYS="${PROM_RETENTION_DAYS:-5}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
GIT_BRANCH="${GIT_BRANCH:-origin/main}"
SSH_ENABLED="${SSH_ENABLED:-0}"
CHECK_LONGHORN="${CHECK_LONGHORN:-0}"
CHECK_CNPG="${CHECK_CNPG:-0}"
CHECK_BGP="${CHECK_BGP:-0}"
LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-longhorn-system}"
LONGHORN_BACKUP_GROUP="${LONGHORN_BACKUP_GROUP:-default}"
LONGHORN_BACKUP_MAX_AGE_H="${LONGHORN_BACKUP_MAX_AGE_H:-26}"
MAJFAULT_THRESHOLD="${MAJFAULT_THRESHOLD:-300}"

# Prometheus HTTP API through the apiserver service proxy (no port-forward).
PROM_API="/api/v1/namespaces/${PROM_NAMESPACE}/services/${PROM_SERVICE}:${PROM_PORT}/proxy/api/v1"

# "90m" / "6h" / "3d" / "3600s" → seconds.
to_seconds()
{
  local VALUE="${1%[smhd]}"
  local UNIT="${1##*[0-9]}"
  case "${UNIT}" in
    s|"") echo "${VALUE}" ;;
    m)    echo $(( VALUE * 60 )) ;;
    h)    echo $(( VALUE * 3600 )) ;;
    d)    echo $(( VALUE * 86400 )) ;;
  esac
}

# Format an epoch in local time: fmt_epoch <epoch> '<strftime format>'.
# BSD date takes -r <epoch>; GNU date takes -d @<epoch> (and -r means "file").
fmt_epoch()
{
  date -r "${1}" "+${2}" 2>/dev/null || date -d "@${1}" "+${2}"
}

# Replace "address" or "address:port" with the node name, for every node in
# NODES. Used to make apiserver/etcd/node-exporter instances readable.
names()
{
  local SED_ARGS=""
  local ENTRY NAME ADDRESS
  for ENTRY in ${NODES}
  do
    NAME="${ENTRY%%:*}"
    ADDRESS="${ENTRY#*:}"
    # Escape dots so the address is matched literally.
    ADDRESS="$(printf '%s' "${ADDRESS}" | sed 's/\./\\./g')"
    SED_ARGS="${SED_ARGS} -e s/${ADDRESS}\(:[0-9][0-9]*\)\{0,1\}/${NAME}/g"
  done
  if [ -n "${SED_ARGS}" ]
  then
    # SED_ARGS is deliberately unquoted: it is a list of "-e expr" words.
    sed ${SED_ARGS}
  else
    cat
  fi
}

# "archer|lana|pam|cheryl" — node names as a regex alternation.
node_names_regex()
{
  local ENTRY OUT=""
  for ENTRY in ${NODES}
  do
    OUT="${OUT:+${OUT}|}${ENTRY%%:*}"
  done
  echo "${OUT}"
}
