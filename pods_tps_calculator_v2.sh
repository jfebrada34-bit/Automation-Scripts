#!/usr/bin/env bash
#
# ==============================================================
# Kubernetes Pods TPS Capacity Checker + Cluster Assessment
# --------------------------------------------------------------
# Requirements:
#   • kubectl with access to the target cluster
#   • jq (brew install jq)
#
# Usage:
#   chmod +x pods_tps_calculator_v5.sh
#   ./pods_tps_calculator_v5.sh
#
# Optional Flags:
#   --cluster-assess   Include cluster resource + HPA + CPU provisioners
# ==============================================================

set -euo pipefail

ASSESS_CLUSTER=false
[[ "${1:-}" == "--cluster-assess" ]] && ASSESS_CLUSTER=true

# ------------------------------
# User Input
# ------------------------------
echo "============================================================="
echo "🔎 Pods TPS Capacity Checker"
echo "============================================================="

read -rp "Forecasted TPS: " FORECAST_TPS
read -rp "TPS per Pod: " TPS_PER_POD
read -rp "Current Pods: " CUR_PODS
read -rp "Namespace Pod Limit (optional): " NS_LIMIT

echo
echo "Select a Time Window:"
echo "1) 1 minute"
echo "2) 1 hour"
echo "3) 8 hours"
read -rp "Choice [1-3] (default 2): " TW_CHOICE
TW_CHOICE=${TW_CHOICE:-2}
case "$TW_CHOICE" in
  1) TIME_WINDOW="1 minute";;
  3) TIME_WINDOW="8 hours";;
  *) TIME_WINDOW="1 hour";;
esac

# ------------------------------
# TPS & Pod Calculations
# ------------------------------
REQUIRED_PODS=$(awk -v tps="$FORECAST_TPS" -v per="$TPS_PER_POD" 'BEGIN {printf "%.0f", (tps/per)}')
EXTRA_PODS=$(( REQUIRED_PODS > CUR_PODS ? REQUIRED_PODS - CUR_PODS : 0 ))
CLUSTER_CAPACITY=$(awk -v pods="$CUR_PODS" -v per="$TPS_PER_POD" 'BEGIN {printf "%.2f", pods * per}')
UTILIZATION=$(awk -v tps="$FORECAST_TPS" -v cap="$CLUSTER_CAPACITY" 'BEGIN {printf "%.2f", (tps/cap)*100}')

echo
echo "==================== ⚡ TPS CAPACITY ===================="
printf "Forecasted TPS           : %s\n" "$FORECAST_TPS"
printf "TPS per Pod              : %s\n" "$TPS_PER_POD"
printf "Current Pods             : %s\n" "$CUR_PODS"
printf "Cluster Capacity (TPS)   : %s\n" "$CLUSTER_CAPACITY"
printf "Pods Required (computed) : %s\n" "$REQUIRED_PODS"
printf "Extra Pods Needed        : %s\n" "$EXTRA_PODS"
printf "Utilization (%%)         : %s\n" "$UTILIZATION"
printf "Time Window              : %s\n" "$TIME_WINDOW"
echo "============================================================="
if (( EXTRA_PODS > 0 )); then
  echo "⚠️  Action Required: Add $EXTRA_PODS pod(s) to meet forecast."
else
  echo "✅ Current pods are sufficient (Need $REQUIRED_PODS pods)."
fi

# ------------------------------
# Cluster Assessment (if enabled)
# ------------------------------
if $ASSESS_CLUSTER; then
  echo
  echo "==================== 🌐 CLUSTER ASSESSMENT ===================="

  NODE_JSON=$(kubectl get nodes -o json 2>/dev/null)
  NODES_READY=$(echo "$NODE_JSON" | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
  TOTAL_CPU=$(echo "$NODE_JSON" | jq '[.items[].status.capacity.cpu | tonumber] | add')
  TOTAL_MEM=$(echo "$NODE_JSON" | jq '[.items[].status.capacity.memory | gsub("Ki";"") | tonumber] | add/1048576' | awk '{printf "%.0f", $1}')
  CUR_RUNNING_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')

  # More accurate max pods using allocatable
  EST_MAX_PODS=$(echo "$NODE_JSON" | jq '[.items[].status.allocatable.pods | tonumber] | add')
  PODS_PER_NODE=$(echo "$NODE_JSON" | jq '[.items[].status.allocatable.pods | tonumber] | add / length | floor')

  TOTAL_AFTER_SCALE=$(( CUR_RUNNING_PODS + EXTRA_PODS ))
  AVAIL_POD_ROOM=$(( EST_MAX_PODS - TOTAL_AFTER_SCALE ))
  EXTRA_PODS_FOR_NODES=$(( REQUIRED_PODS > EST_MAX_PODS ? REQUIRED_PODS - EST_MAX_PODS : 0 ))

  # Nodes needed to accommodate extra pods (if any)
  if (( EXTRA_PODS_FOR_NODES > 0 )); then
    NODES_TO_ADD=$(( (EXTRA_PODS_FOR_NODES + PODS_PER_NODE - 1) / PODS_PER_NODE ))
  else
    NODES_TO_ADD=0
  fi

  printf "Nodes Ready              : %s\n" "$NODES_READY"
  printf "Total CPU (cores)        : %s\n" "$TOTAL_CPU"
  printf "Total Memory (Gi)        : %s\n" "$TOTAL_MEM"
  printf "Current Running Pods     : %s\n" "$CUR_RUNNING_PODS"
  printf "Estimated Max Pods       : %s\n" "$EST_MAX_PODS"
  printf "Additional Pods Needed   : %s\n" "$EXTRA_PODS"
  echo "----------------------------------------------"
  printf "TOTAL Pods After Scaling : %s\n" "$TOTAL_AFTER_SCALE"
  printf "Available Pod Room       : %s\n" "$AVAIL_POD_ROOM"
  echo "----------------------------------------------"
  if (( NODES_TO_ADD > 0 )); then
    echo "⚠️  Recommendation: Add approximately $NODES_TO_ADD node(s) to support scaling."
  else
    echo "✅ Cluster has enough capacity (no node increase required)."
  fi
fi

echo
echo "==================== 📊 NAMESPACE HPA STATUS ===================="
printf "%-18s %-36s %-24s %-4s %-4s %-4s %s\n" \
  "NAMESPACE" "HPA NAME" "CPU / MEM" "MIN" "CUR" "MAX" "AGE"
printf "%-18s %-36s %-24s %-4s %-4s %-4s %s\n" \
  "------------------" "------------------------------------" "------------------------" "----" "----" "----" "----"

kubectl get hpa -A -o json 2>/dev/null \
| jq -r '
  .items[]
  | [
      .metadata.namespace,
      .metadata.name,
      (
        "cpu:" +
        (
          (
            [.status.currentMetrics[]? | select(.resource.name=="cpu") | .resource.current.averageUtilization][0]
          ) // "n/a"
          | tostring +
          (if . != "n/a" then "%" else "" end)
        ) +
        " mem:" +
        (
          (
            [.status.currentMetrics[]? | select(.resource.name=="memory") | .resource.current.averageValue][0]
          ) // "n/a"
          | if . != "n/a"
              then
                # Convert to Mi (MiB) from bytes
                ((tonumber / 1048576) | floor | tostring) + "Mi"
              else "n/a"
            end
        )
      ),
      (.spec.minReplicas|tostring),
      (.status.currentReplicas|tostring),
      (.spec.maxReplicas|tostring),
      (((now - (.metadata.creationTimestamp|fromdateiso8601))/86400 | floor | tostring) + "d")
    ]
    | @tsv' \
| while IFS=$'\t' read -r ns name metrics min cur max age; do
    printf "%-18s %-36s %-24s %-4s %-4s %-4s %s\n" \
      "$ns" "$name" "$metrics" "$min" "$cur" "$max" "$age"
  done

echo
echo "==================== 💡 CPU PROVISIONERS ===================="
echo "(Values from 'kubectl describe provisioner <name> | grep Cpu')"
echo "-------------------------------------------------------------"
printf "%-25s %-15s %-15s\n" "Provisioner" "Max CPU Quota" "Current CPU Allocation"

# Capture provisioners safely
PROVISIONERS=$(kubectl get provisioner --no-headers 2>/dev/null | awk '{print $1}' || true)

if [[ -z "$PROVISIONERS" ]]; then
  echo "⚠️  No provisioners found or unable to list them."
else
  for prov in $PROVISIONERS; do
    CPU_LINES=$(kubectl describe provisioner "$prov" 2>/dev/null | grep -i "Cpu" || true)
    MAX_CPU=$(echo "$CPU_LINES" | awk '/Cpu:/ {print $2}' | head -n1)
    CUR_CPU=$(echo "$CPU_LINES" | awk '/Cpu:/ {print $2}' | tail -n1)
    printf "%-25s %-15s %-15s\n" "$prov" "${MAX_CPU:-n/a}" "${CUR_CPU:-n/a}"
  done
fi

echo
echo "Notes:"
echo "• Max CPU Quota = upper CPU allocation allowed for scaling."
echo "• Current CPU Allocation = CPU currently assigned to running nodes."
echo "• If n/a, scaling relies on cluster-wide quotas or instance types."
echo "============================================================="

