#!/bin/bash
# =============================================================================
# promr.sh — Prometheus range query through the apiserver service proxy.
#
# Usage:  promr.sh '<promql>' <range> <step> [label1,label2,...] [min]
#
#   range   how far back from now: 90m, 6h, 3d (up to Prometheus retention)
#   step    sample spacing: 60s, 5m, 1h
#   labels  optional comma list of labels to print instead of all of them
#   min     optional: print only samples whose value is > min (e.g. 0 to see
#           only the moments an alert/counter was non-zero)
#
# Prints one line per series: "<labels>: HH:MM=value HH:MM=value ...", in
# LOCAL time (the cluster logs and container timestamps are UTC — convert
# before correlating).
# =============================================================================
set -o pipefail

. "$(cd "$(dirname "${0}")" && pwd)/lib.sh"
PROM_PATH="${PROM_API}/query_range"
QUERY="${1:?usage: promr.sh '<promql>' <range> <step> [labels] [min]}"
RANGE="${2:?range missing, e.g. 6h}"
STEP="${3:?step missing, e.g. 5m}"
LABELS="${4:-}"
MIN="${5:-}"

END="$(date +%s)"
RANGE_S="$(to_seconds "${RANGE}")"
START=$(( END - RANGE_S ))
STEP_S="$(to_seconds "${STEP}")"
# Prometheus refuses more than 11,000 points per series; widen the step if needed.
if [ $(( RANGE_S / STEP_S )) -gt 10000 ]
then
  STEP_S=$(( RANGE_S / 10000 + 1 ))
  echo "(step widened to ${STEP_S}s to stay under Prometheus' 11k-point limit)" >&2
fi
ENCODED="$(jq -rn --arg q "${QUERY}" '$q|@uri')"

kubectl get --raw "${PROM_PATH}?query=${ENCODED}&start=${START}&end=${END}&step=${STEP_S}" \
  | jq -r --arg labels "${LABELS}" --arg min "${MIN}" '
      def fmt: tonumber | (. * 10 | round) / 10 | tostring;
      # Show the date only when the range spans more than one day.
      def ts($span): localtime | strftime(if ($span > 86400) then "%m-%d %H:%M" else "%H:%M" end);
      ((.data.result[0].values // [[0]]) as $v | ($v[-1][0] - $v[0][0])) as $span
      | .data.result[]
      | (if $labels == "" then
           (.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" "))
         else
           ((.metric as $m | [$labels | split(",")[] as $l | "\($l)=\($m[$l] // "-")"]) | join(" "))
         end) as $lbl
      | [.values[]
         | select($min == "" or ((.[1] | tonumber) > ($min | tonumber)))
         | "\(.[0] | ts($span))=\(.[1] | fmt)"] as $pts
      | select(($pts | length) > 0)
      | "\(if $lbl == "" then "{}" else $lbl end): \($pts | join(" "))"'
