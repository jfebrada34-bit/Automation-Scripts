#!/usr/bin/env bash
#
# ================================================================
#  TPS Capacity Checker v5
#  ---------------------------------------------------------------
#  This script estimates Kubernetes cluster sizing based on:
#    • Total Transactions / Time Period → TPS (24×7 or 8-hour)
#    • Pod tested TPS capacity
#    • Node CPU/Memory capacity
#    • HPA burst factor
#
#  OUTPUT:
#    • Required pods, HPA settings
#    • Per-pod CPU/Memory requests & limits
#    • Cluster total CPU/Memory (with 30% buffer)
#    • Node sizing and cost estimate
# ================================================================

# Default values
ISTIO_ENABLED="y"
CALC_FROM_TOTAL="y"
DEFAULT_NODE_CPU=4000     # mCPU
DEFAULT_NODE_MEM=16384    # Mi
DEFAULT_HPA_BURST=2.0
CPU_TRIGGER=60
POD_CPU_REQUEST=100       # mCPU
POD_CPU_LIMIT=1000        # mCPU
ISTIO_CPU_REQUEST=150     # mCPU
ISTIO_CPU_LIMIT=100       # mCPU
POD_MEM_REQUEST=2000      # Mi
POD_MEM_LIMIT=4000        # Mi
DEFAULT_TPS_PER_POD=400

read -p "========== TPS Capacity Checker ==========\nIs Istio enabled? (y/n) [${ISTIO_ENABLED}]: " input
ISTIO_ENABLED=${input:-$ISTIO_ENABLED}

read -p "Do you want to calculate TPS from total transactions? (y/n) [${CALC_FROM_TOTAL}]: " input
CALC_FROM_TOTAL=${input:-$CALC_FROM_TOTAL}

if [[ "$CALC_FROM_TOTAL" == "y" ]]; then
  read -p "Enter total number of transactions (monthly or period total) [0]: " TOTAL_TX
  TOTAL_TX=${TOTAL_TX:-0}
  read -p "Enter time period in days for that total [30]: " DAYS
  DAYS=${DAYS:-30}

  TPS_24x7=$(awk "BEGIN {printf \"%.6f\", $TOTAL_TX/($DAYS*24*60*60)}")
  TPS_8HR=$(awk "BEGIN {printf \"%.6f\", $TOTAL_TX/($DAYS*8*60*60)}")

  echo -e "\n💡 TPS formula reference"
  printf "   24×7  => %.6f TPS/sec  |  %.2f TPS/min  |  %.2f TPS/hr\n" \
         "$TPS_24x7" "$(awk "BEGIN {print $TPS_24x7*60}")" "$(awk "BEGIN {print $TPS_24x7*3600}")"
  printf "   8-hour => %.6f TPS/sec  |  %.2f TPS/min  |  %.2f TPS/hr\n" \
         "$TPS_8HR" "$(awk "BEGIN {print $TPS_8HR*60}")" "$(awk "BEGIN {print $TPS_8HR*3600}")"

  read -p "Use 24×7 TPS [1] or 8-hour TPS [2] [1]: " MODE
  MODE=${MODE:-1}
  if [[ "$MODE" == "2" ]]; then
    TPS=$TPS_8HR
    MODE_TXT="8-hour"
  else
    TPS=$TPS_24x7
    MODE_TXT="24×7"
  fi
else
  read -p "Enter required TPS (transactions per second) [0]: " TPS
  TPS=${TPS:-0}
  MODE_TXT="Custom"
fi

read -p "Enter Tested TPS each pod can handle [${DEFAULT_TPS_PER_POD}]: " POD_TPS
POD_TPS=${POD_TPS:-$DEFAULT_TPS_PER_POD}
read -p "Enter node CPU capacity (mCPU) [${DEFAULT_NODE_CPU}]: " NODE_CPU
NODE_CPU=${NODE_CPU:-$DEFAULT_NODE_CPU}
read -p "Enter node Memory capacity (Mi) [${DEFAULT_NODE_MEM}]: " NODE_MEM
NODE_MEM=${NODE_MEM:-$DEFAULT_NODE_MEM}
read -p "Enter HPA burst factor (e.g. 2.0) [${DEFAULT_HPA_BURST}]: " HPA_BURST
HPA_BURST=${HPA_BURST:-$DEFAULT_HPA_BURST}

# === Calculations ===
MIN_PODS=$(awk "BEGIN {printf \"%d\", ($TPS/$POD_TPS < 1)?1:($TPS/$POD_TPS)}")
HPA_MIN=$MIN_PODS
HPA_MAX=$(awk "BEGIN {printf \"%.0f\", $HPA_BURST * $HPA_MIN}")

# Per-pod CPU Request total (Pod + Istio if enabled)
if [[ "$ISTIO_ENABLED" == "y" ]]; then
  PER_POD_REQ=$((POD_CPU_REQUEST + ISTIO_CPU_REQUEST))
  PER_POD_LIMIT=$((POD_CPU_LIMIT + ISTIO_CPU_LIMIT))
else
  PER_POD_REQ=$POD_CPU_REQUEST
  PER_POD_LIMIT=$POD_CPU_LIMIT
fi

# Cluster totals
TOTAL_CPU_REQ=$(awk "BEGIN {print $PER_POD_REQ * $MIN_PODS}")
TOTAL_CPU_REQ_CORES=$(awk "BEGIN {print $TOTAL_CPU_REQ/1000}")
BUFFERED_CPU_REQ_CORES=$(awk "BEGIN {print $TOTAL_CPU_REQ_CORES*1.3}")
TOTAL_MEM_REQ=$(awk "BEGIN {print $POD_MEM_REQUEST * $MIN_PODS}")

# Nodes needed
NODES_CPU=$(awk "BEGIN {printf \"%.0f\", ($TOTAL_CPU_REQ/$NODE_CPU) < 1 ? 1 : ($TOTAL_CPU_REQ/$NODE_CPU)}")
NODES_MEM=$(awk "BEGIN {printf \"%.0f\", ($TOTAL_MEM_REQ/$NODE_MEM) < 1 ? 1 : ($TOTAL_MEM_REQ/$NODE_MEM)}")
RECOMMENDED_NODES=$(( NODES_CPU > NODES_MEM ? NODES_CPU : NODES_MEM ))

# Istio-inclusive CPU Capacity
ISTIO_TOTAL_CAP=$(awk "BEGIN {print ($POD_CPU_LIMIT + $ISTIO_CPU_LIMIT) * $HPA_MAX}")
ISTIO_TOTAL_CORES=$(awk "BEGIN {print $ISTIO_TOTAL_CAP/1000}")

# Cost estimate (simple range based on CPU cores)
COST_MIN=$(awk "BEGIN {printf \"%.2f\", $BUFFERED_CPU_REQ_CORES*107}")
COST_MAX=$(awk "BEGIN {printf \"%.2f\", $BUFFERED_CPU_REQ_CORES*285}")

# === OUTPUT ===
echo -e "\n📊 Production Cluster Sizing Report"
echo "--------------------------------------------------"
echo "Traffic Forecast (mode): $MODE_TXT"
printf "• Required TPS (per sec)  : %.2f TPS\n" "$TPS"
printf "• Each pod tested TPS      : %.2f TPS/pod\n" "$POD_TPS"
printf "• Minimum pods needed      : %d pods\n" "$MIN_PODS"
printf "• HPA min / HPA max        : %d / %s\n" "$HPA_MIN" "$HPA_MAX"
printf "• HPA CPU trigger          : %d%%\n" "$CPU_TRIGGER"

echo -e "\nPer-pod Requests (mCPU)"
printf "• Pod CPU request (base)   : %d m\n" "$POD_CPU_REQUEST"
[[ "$ISTIO_ENABLED" == "y" ]] && printf "• Istio CPU request        : %d m\n" "$ISTIO_CPU_REQUEST"
printf "• Per-pod total request    : %d m (pod %dm + istio %dm)\n" "$PER_POD_REQ" "$POD_CPU_REQUEST" "$ISTIO_CPU_REQUEST"
printf "• Pod CPU limit (per pod)  : %d m\n" "$POD_CPU_LIMIT"

echo -e "\nCluster Totals (requests)"
printf "• Total CPU requests (m)   : %.0f mCPU\n" "$TOTAL_CPU_REQ"
printf "• Total CPU requests (cores): %.2f cores\n" "$TOTAL_CPU_REQ_CORES"
printf "• Total CPU (+30%% buffer)  : %.2f cores\n" "$BUFFERED_CPU_REQ_CORES"
printf "• Total Memory requests    : %.0f Mi\n" "$TOTAL_MEM_REQ"

echo -e "\nNode Sizing Estimate"
printf "• Single node CPU cap (m)  : %d mCPU\n" "$NODE_CPU"
printf "• Single node Mem cap (Mi) : %d Mi\n" "$NODE_MEM"
printf "• Nodes needed (CPU)       : %d\n" "$NODES_CPU"
printf "• Nodes needed (Memory)    : %d\n" "$NODES_MEM"
printf "• ➜ Recommended nodes      : %d\n" "$RECOMMENDED_NODES"

echo -e "\nCost Estimate"
printf "• Monthly cost (est)       : $%.2f – $%.2f (30%% buffer applied)\n" "$COST_MIN" "$COST_MAX"

echo -e "\nIstio-inclusive CPU Capacity (safety check)"
printf "• Formula                   : (Pod CPU LIMIT + Istio CPU LIMIT) × HPA Max\n"
printf "• ➜ Total Istio-inclusive   : %.0f mCPU (~ %.2f cores)\n" "$ISTIO_TOTAL_CAP" "$ISTIO_TOTAL_CORES"

echo -e "\nCluster          Namespace    Pods   Pod Specs            CPUReq   CPULim   MemReq   MemLim   HPAmin HPAmax CPUTrig"
printf "default          default      %d      %dmCPU / %dMi   %dm     %dm   %dMi   %dMi   %d    %s   %d%%\n" \
       "$MIN_PODS" "$POD_CPU_LIMIT" "$POD_MEM_LIMIT" "$POD_CPU_REQUEST" "$POD_CPU_LIMIT" \
       "$POD_MEM_REQUEST" "$POD_MEM_LIMIT" "$HPA_MIN" "$HPA_MAX" "$CPU_TRIGGER"
echo "--------------------------------------------------"
