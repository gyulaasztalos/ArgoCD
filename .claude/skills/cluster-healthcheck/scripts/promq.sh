#!/bin/bash
# =============================================================================
# promq.sh — instant Prometheus query through the apiserver service proxy.
#
# Usage:  promq.sh '<promql>' [label1,label2,...]
#
# Prints one line per series: "<labels>  <value>". With a label list, only
# those labels are printed (in that order), which keeps the noisy
# endpoint/job/service labels out of the output.
#
# No port-forward needed: kubectl's current context reaches Prometheus via the
# apiserver service proxy; namespace/service/port come from cluster.conf.
# =============================================================================
set -o pipefail

. "$(cd "$(dirname "${0}")" && pwd)/lib.sh"
PROM_PATH="${PROM_API}/query"
QUERY="${1:?usage: promq.sh '<promql>' [label1,label2,...]}"
LABELS="${2:-}"

# URL-encode the PromQL so braces, quotes and spaces survive the GET.
ENCODED="$(jq -rn --arg q "${QUERY}" '$q|@uri')"

kubectl get --raw "${PROM_PATH}?query=${ENCODED}" \
  | jq -r --arg labels "${LABELS}" '
      # Round to 3 decimals so the output stays readable.
      def fmt: tonumber | (. * 1000 | round) / 1000 | tostring;
      .data.result[]
      | (if $labels == "" then
           (.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" "))
         else
           ((.metric as $m | [$labels | split(",")[] as $l | "\($l)=\($m[$l] // "-")"]) | join(" "))
         end) as $lbl
      | "\($lbl)  \(.value[1] | fmt)"'
