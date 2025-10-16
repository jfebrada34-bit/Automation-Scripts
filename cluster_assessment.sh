#!/usr/bin/env bash
#
# Cluster Assessment Tool v2
# ---------------------------
# Features:
# • Assesses cluster capacity, nodes, and pod utilization.
# • Filters by Namespace and HPA name.
#
# Requirements:
#   brew install jq
#   kubectl must be configured for the target cluster.

set -euo pipefail

### FUNCTIONS ###

read_inputs() {
  echo "============================================================="
  echo "🔎 Cluster Assessment Tool (with namespace & HPA filters)"
  echo "============================================================="
  read -rp "Filter by Namespace (press Enter to show all): " NAMESPACE_FILTER
  read -rp "Filter by HPA Name (press Enter to show all): " HPA_FILTER
}

cluster_assessment() {
  echo
  echo "==================== 🌐 CLUSTER ASSESSMENT ===================="

  NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")
  TOTAL_CPU=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[].status.capacity.cpu|tonumber] | add')
  TOTAL_MEM=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[].status.capacity.memory | capture("(?<num>[0-9]+)(?<unit>.*)") |
      if .unit=="Ki" then (.num|tonumber/1048576)
      elif .unit=="Mi" then (.num|tonumber/1024)
      elif .unit=="Gi" then (.num|tonumber)
      else (.num|tonumber/1073741824)
      end] | add' | awk '{printf "%.0f", $1}')

  # If namespace filter is set, count pods only in that namespace
  if [[ -z "$NAMESPACE_FILTER" ]]; then
    RUNNING_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | xargs)
  else
    RUNNING_PODS=$(kubectl get pods -n "$NAMESPACE_FILTER" --no-headers 2>/dev/null | wc -l | xargs)
  fi

  MAX_PODS=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[].status.capacity.pods|tonumber] | add')

  printf "Nodes Ready              : %s\n" "$NODES_READY"
  printf "Total CPU (cores)        : %s\n" "$TOTAL_CPU"
  printf "Total Memory (Gi)        : %s\n" "$TOTAL_MEM"
  printf "Current Running Pods     : %s\n" "$RUNNING_PODS"
  printf "Estimated Max Pods       : %s\n" "$MAX_PODS"
  echo "----------------------------------------------"

  AVAILABLE_ROOM=$(( MAX_PODS - RUNNING_PODS ))
  printf "Available Pod Room       : %s\n" "$AVAILABLE_ROOM"
  echo "----------------------------------------------"

  if (( AVAILABLE_ROOM < 0 )); then
    echo "⚠️  Cluster may need additional nodes to support scaling."
  else
    echo "✅ Cluster has enough capacity (no node increase required)."
  fi
}

show_hpa_status() {
  echo
  echo "==================== 📊 NAMESPACE HPA STATUS ===================="
  printf "%-18s %-90s %-10s %-8s %-4s %-4s %-4s\n" \
    "NAMESPACE" "HPA NAME" "CPU(%)" "MEM(%)" "MIN" "CUR" "MAX"
  printf "%-18s %-90s %-10s %-8s %-4s %-4s %-4s\n" \
    "------------------" \
    "------------------------------------------------------------------------------------------" \
    "----------" "--------" "----" "----" "----"

  NOW_EPOCH=$(date +%s)

  kubectl get hpa --all-namespaces -o json 2>/dev/null \
  | jq -r --argjson now "$NOW_EPOCH" '
      .items[]
      | [
          (.metadata.namespace // "n/a"),
          (.metadata.name // "n/a"),
          (
            ( .status.currentMetrics // [] 
              | map(select(.resource.name=="cpu") 
                     | (.resource.current.averageUtilization // empty))
              | if length>0 then .[0]|tostring else "n/a" end )
          ),
          (
            ( .status.currentMetrics // []
              | map(
                  (select(.resource.name=="memory") 
                     | (.resource.current.averageUtilization // empty))
              )
              | if length>0 then .[0]|tostring else "n/a" end )
          ),
          (.spec.minReplicas // "n/a"),
          (.status.currentReplicas // "n/a"),
          (.spec.maxReplicas // "n/a")
        ]
      | @tsv
  ' | awk -v ns="$NAMESPACE_FILTER" -v hpa="$HPA_FILTER" '
      BEGIN {
        OFS="\t"
        gsub(/^[ \t]+|[ \t]+$/, "", ns)
        gsub(/^[ \t]+|[ \t]+$/, "", hpa)
        ns  = tolower(ns)
        hpa = tolower(hpa)
      }
      {
        ns_match  = (ns==""  || index(tolower($1), ns)  > 0)
        hpa_match = (hpa=="" || index(tolower($2), hpa) > 0)
        if (ns_match && hpa_match)
          printf "%-18s %-90s %-10s %-8s %-4s %-4s %-4s\n", \
                 $1,$2,$3,$4,$5,$6,$7
      }'
}

show_cpu_provisioners() {
  echo
  echo "==================== 💡 CPU PROVISIONERS ===================="
  echo "(Values from 'kubectl describe provisioner <name> | grep Cpu')"
  echo "-------------------------------------------------------------"
  printf "%-25s %-15s %-15s\n" "Provisioner" "Max CPU Quota" "Current CPU Allocation"

  for prov in $(kubectl get provisioner --no-headers 2>/dev/null | awk '{print $1}'); do
    if [[ -z "$NAMESPACE_FILTER" || "$prov" =~ $NAMESPACE_FILTER ]]; then
      CPU_LINES=$(kubectl describe provisioner "$prov" 2>/dev/null | grep -i "Cpu" || true)
      MAX_CPU=$(echo "$CPU_LINES" | awk '/Cpu:/ {print $2}' | head -n1)
      CUR_CPU=$(echo "$CPU_LINES" | awk '/Cpu:/ {print $2}' | tail -n1)
      printf "%-25s %-15s %-15s\n" "$prov" "${MAX_CPU:-n/a}" "${CUR_CPU:-n/a}"
    fi
  done

  echo
  echo "Notes:"
  echo "• Max CPU Quota = upper CPU allocation allowed for scaling."
  echo "• Current CPU Allocation = CPU currently assigned to running nodes."
  echo "• Namespace filter is applied as a *name match* for provisioners."
  echo "============================================================="
}

### MAIN ###
if [[ "${1:-}" == "--cluster-assess" ]]; then
  read_inputs
  cluster_assessment
  show_hpa_status
  show_cpu_provisioners
else
  echo "Usage: $0 --cluster-assess"
fi
