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
# No port-forward needed: kubectl's current context reaches Prometheus via
# /api/v1/namespaces/monitoring/services/<svc>:9090/proxy.
# =============================================================================
set -o pipefail

PROM_PATH="/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query"
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
