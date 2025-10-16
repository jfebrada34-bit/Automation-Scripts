#!/usr/bin/env bash
#
# ============================================================================
# TPS Capacity Checker v5 – Production Standard (interactive & corrected)
# ============================================================================
# - Uses Production pod/HPA specs as baseline.
# - Supports Istio overhead if enabled.
# - Calculates Pods, HPA Range, Node Estimates.
# - Fixed interactivity & correct ceil(...) behavior for pod counts.
# ============================================================================
# Requirements: bash, bc, awk
# ----------------------------------------------------------------------------

set -euo pipefail

echo "========== TPS Capacity Checker =========="

# ---------------------- Environment / Production Standards --------------------
ENV="Production"
HPA_MIN_STD=3
HPA_MAX_STD=64
CPU_TRIGGER_STD=60
# Default Pod Specs (production)
BASE_CPU_REQ=100    # mCPU baseline request
BASE_CPU_LIM=1000   # mCPU limit
BASE_MEM_REQ=2000   # Mi baseline
BASE_MEM_LIM=2000   # Mi limit
# Node defaults
NODE_CPU=4000       # mCPU (4 vCPU)
NODE_MEM=16384      # MiB (16 GiB)

# ---------------------- Istio --------------------
read -rp "Is Istio enabled? (y/n) [default y]: " ISTIO
ISTIO=${ISTIO:-y}
if [[ "$ISTIO" =~ ^[Yy]$ ]]; then
    CPU_REQ=$(( BASE_CPU_REQ + 150 ))  # 250m request (with Istio overhead)
    CPU_LIM=$BASE_CPU_LIM
    MEM_REQ=$BASE_MEM_REQ
    MEM_LIM=1000                        # per provided table override
else
    CPU_REQ=$BASE_CPU_REQ
    CPU_LIM=$BASE_CPU_LIM
    MEM_REQ=$BASE_MEM_REQ
    MEM_LIM=$BASE_MEM_LIM
fi

# ---------------------- TPS Input --------------------
read -rp "Do you want to calculate TPS from total transactions? (y/n): " USE_TXN
USE_TXN=${USE_TXN:-n}
if [[ "$USE_TXN" =~ ^[Yy]$ ]]; then
    read -rp "Enter total number of transactions: " TOTAL_TXN
    read -rp "Enter time period in days (e.g., 1 for 1 day, 30 for 30 days): " DAYS
    # protect against empty or zero
    DAYS=${DAYS:-1}
    if (( DAYS <= 0 )); then DAYS=1; fi
    SECONDS=$(( DAYS * 24 * 60 * 60 ))
    ADD_TPS=$(echo "scale=6; $TOTAL_TXN / $SECONDS" | bc -l)
    printf -- "Derived TPS from %s transactions over %d day(s): %.6f TPS\n" "$TOTAL_TXN" "$DAYS" "${ADD_TPS:-0}"
else
    read -rp "Enter Additional TPS (forecasted traffic): " ADD_TPS
    ADD_TPS=${ADD_TPS:-0}
fi

# ---------------------- Pod / Node Inputs --------------------
read -rp "Enter Tested TPS each Pod can handle (default 1): " TPS_PER_POD
TPS_PER_POD=${TPS_PER_POD:-1}
# ensure non-zero
if awk 'BEGIN{exit(ARGC==1?1:0)}' "$TPS_PER_POD" 2>/dev/null; then :; fi

read -rp "Enter Node CPU capacity (mCPU, default 4000): " NODE_CPU_INPUT
NODE_CPU=${NODE_CPU_INPUT:-$NODE_CPU}
read -rp "Enter Node Memory capacity (MiB, default 16384): " NODE_MEM_INPUT
NODE_MEM=${NODE_MEM_INPUT:-$NODE_MEM}

# ---------------------- Calculations --------------------
# Required pods = ceil( ADD_TPS / TPS_PER_POD ). If ADD_TPS == 0 -> 0 required.
REQUIRED_PODS=$(awk -v a="$ADD_TPS" -v b="$TPS_PER_POD" 'BEGIN{
  if (b==0) { print 0; exit }
  if (a<=0) { print 0; exit }
  x = a / b;
  ix = int(x);
  if (x > ix) ix = ix + 1;
  printf "%d", ix
}')

# HPA: Recommend standard HPA_MIN (3) and compute HPA_MAX based on CPU trigger (ceil)
HPA_MIN=$HPA_MIN_STD
HPA_MAX=$(awk -v rp="$REQUIRED_PODS" -v trig="$CPU_TRIGGER_STD" -v cap="$HPA_MAX_STD" 'BEGIN{
  if (trig<=0) trig=60;
  if (rp<=0) { print 1; exit }
  x = rp * 100 / trig;
  ix = int(x);
  if (x > ix) ix = ix + 1;
  if (ix < 1) ix = 1;
  if (ix > cap) ix = cap;
  print ix
}')

# Node sizing - compute pods-per-node on CPU and Memory and pick min
pods_per_node_cpu=$(awk -v nc="$NODE_CPU" -v cr="$CPU_REQ" 'BEGIN{ if(cr<=0) {print 0; exit} print int(nc/cr) }')
pods_per_node_mem=$(awk -v nm="$NODE_MEM" -v mr="$MEM_REQ" 'BEGIN{ if(mr<=0) {print 0; exit} print int(nm/mr) }')

# pods_per_node is the min positive integer of the two resource constraints
if (( pods_per_node_cpu <= 0 || pods_per_node_mem <= 0 )); then
  pods_per_node=0
else
  pods_per_node=$(( pods_per_node_cpu < pods_per_node_mem ? pods_per_node_cpu : pods_per_node_mem ))
fi

if (( pods_per_node > 0 )); then
  REQUIRED_NODES=$(( (REQUIRED_PODS + pods_per_node - 1) / pods_per_node ))
else
  # fallback: one pod per node (if pod is larger than node)
  if (( REQUIRED_PODS > 0 )); then
    REQUIRED_NODES=$REQUIRED_PODS
  else
    REQUIRED_NODES=0
  fi
fi

# If required pods is 0, still recommend HPA min = 3 but clarify
# Note: production standard HPA min is shown separately (no forced override of required pods)

# ---------------------- Projections --------------------
TX_1MIN=$(echo "scale=2; $ADD_TPS * 60" | bc -l)
TX_1HR=$(echo "scale=2; $ADD_TPS * 3600" | bc -l)
TX_8HR=$(echo "scale=2; $ADD_TPS * 28800" | bc -l)
TX_1DAY=$(echo "scale=2; $ADD_TPS * 86400" | bc -l)
TX_30D_24H=$(echo "scale=2; $ADD_TPS * 2592000" | bc -l)
TX_30D_8H=$(echo "scale=2; $ADD_TPS * 864000" | bc -l)

# ---------------------- Report (safe printing with -- and defaults) -------------
printf -- "\n📊 Production Cluster Sizing Report\n"
printf -- "--------------------------------------------------\n"

printf -- "Traffic Forecast\n"
printf -- "• Required TPS             : ~%.2f\n" "${ADD_TPS:-0}"
printf -- "• Pod TPS capacity         : %.2f\n" "${TPS_PER_POD:-1}"
if (( REQUIRED_PODS > 0 )); then
  printf -- "• ➜ Minimum Pods Needed    : %d (ceil)\n\n" "$REQUIRED_PODS"
else
  printf -- "• ➜ Minimum Pods Needed    : 0 (no traffic)\n\n"
fi

printf -- "HPA Recommendation (Production Standard)\n"
printf -- "• HPA Min                  : %d\n" "$HPA_MIN"
printf -- "• HPA Max                  : %d\n" "$HPA_MAX"
printf -- "• CPU Trigger              : %d%%\n\n" "$CPU_TRIGGER_STD"

printf -- "Pod Specification (Production Standard)\n"
printf -- "• CPU Request / Limit      : %dm / %dm\n" "${CPU_REQ:-0}" "${CPU_LIM:-0}"
printf -- "• Memory Request / Limit   : %dMi / %dMi\n" "${MEM_REQ:-0}" "${MEM_LIM:-0}"
printf -- "• Istio Enabled            : %s\n\n" "$( [[ "$ISTIO" =~ ^[Yy]$ ]] && echo "Yes" || echo "No" )"

printf -- "Node Sizing Estimate\n"
printf -- "• Node CPU Capacity        : %dm\n" "${NODE_CPU:-0}"
printf -- "• Node Memory Capacity     : %dMi\n" "${NODE_MEM:-0}"
if (( pods_per_node > 0 )); then
  printf -- "• Pods per Node (CPU)      : %d\n" "$pods_per_node_cpu"
  printf -- "• Pods per Node (Memory)   : %d\n" "$pods_per_node_mem"
  printf -- "• ➜ Estimated Nodes Needed : %d\n\n" "$REQUIRED_NODES"
else
  printf -- "• Pods per Node (CPU)      : %d\n" "$pods_per_node_cpu"
  printf -- "• Pods per Node (Memory)   : %d\n" "$pods_per_node_mem"
  printf -- "• ➜ Estimated Nodes Needed : %d (one pod per node fallback)\n\n" "$REQUIRED_NODES"
fi

printf -- "Traffic Projection (if rate stays the same)\n"
printf -- "• In 1 minute              : ~%.2f transactions\n" "${TX_1MIN:-0}"
printf -- "• In 1 hour                : ~%.2f transactions\n" "${TX_1HR:-0}"
printf -- "• In 8 hours               : ~%.2f transactions\n" "${TX_8HR:-0}"
printf -- "• In 1 day (24h)          : ~%.2f transactions\n" "${TX_1DAY:-0}"
printf -- "• In 30 days (24h)        : ~%.2f transactions\n" "${TX_30D_24H:-0}"
printf -- "• In 30 days (8h)         : ~%.2f transactions\n" "${TX_30D_8H:-0}"
printf -- "--------------------------------------------------\n\n"

# Helpful final note
if (( REQUIRED_PODS == 0 )); then
  printf -- "Note: calculated required pods is 0 (no traffic). HPA Min is %d for Production deployments.\n" "$HPA_MIN"
else
  printf -- "Note: 'Minimum Pods Needed' is the mathematical ceiling of (TPS required ÷ TPS per pod).\n"
  printf -- "      HPA Min/Max are Production defaults; set HPA min to %d if you require that minimum baseline.\n\n" "$HPA_MIN"
fi

exit 0
