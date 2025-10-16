#!/usr/bin/env bash

# --- Validators ---
validate_float() {
    # accepts: 123, 123.45
    if ! [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "❌ Error: $2 must be a non-negative number (decimals allowed)." >&2
        exit 1
    fi
}

validate_int() {
    # accepts: 0, 1, 2...
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: $2 must be a non-negative integer." >&2
        exit 1
    fi
}

echo "========== Pods TPS Capacity Checker =========="

read -rp "Enter Additional TPS (forecasted traffic): " ADD_TPS
validate_float "$ADD_TPS" "Additional TPS"

read -rp "Enter TPS per Pod: " TPS_PER_POD
validate_float "$TPS_PER_POD" "TPS per Pod"
# prevent division by zero
if awk -v x="$TPS_PER_POD" 'BEGIN{exit(x<=0)}'; then
    true
else
    echo "❌ Error: TPS per Pod must be greater than 0." >&2
    exit 1
fi

read -rp "Enter Current Number of Pods: " CURRENT_PODS
validate_int "$CURRENT_PODS" "Current Pods"

read -rp "Enter Cluster/Namespace Pod Limit (optional, press Enter to skip): " MAX_PODS
if [[ -n "$MAX_PODS" ]]; then
    validate_int "$MAX_PODS" "Cluster/Namespace Pod Limit"
fi

echo
echo "Select a Time Window for Transaction Calculation:"
echo "1) 1 minute"
echo "2) 1 hour"
echo "3) 8 hours"
read -rp "Enter choice [1-3] (default 2): " TIME_CHOICE
TIME_CHOICE=${TIME_CHOICE:-2}

case "$TIME_CHOICE" in
    1) SECONDS=60;    LABEL="1 minute" ;;
    2) SECONDS=3600;  LABEL="1 hour"   ;;
    3) SECONDS=28800; LABEL="8 hours"  ;;
    *) echo "⚠️ Invalid choice. Defaulting to 1 hour."; SECONDS=3600; LABEL="1 hour" ;;
esac

# --- Calculations (float-safe using awk) ---
TOTAL_CAPACITY=$(awk -v a="$TPS_PER_POD" -v b="$CURRENT_PODS" 'BEGIN{printf "%.4f", a*b}')
# REQUIRED_PODS = ceil( ADD_TPS / TPS_PER_POD ). Result is integer >=0
REQUIRED_PODS=$(awk -v a="$ADD_TPS" -v b="$TPS_PER_POD" 'BEGIN{ if(b==0){print 0; exit} v=a/b; if(v<=0) print 0; else if(v==int(v)) print int(v); else print int(v)+1 }')
UTILIZATION=$(awk -v a="$ADD_TPS" -v b="$TOTAL_CAPACITY" 'BEGIN{ if(b==0){print "N/A"; exit} printf "%.2f", (a/b)*100 }')
# Transactions over window: show both exact (with decimals) and rounded integer
ADDITIONAL_TX_EXACT=$(awk -v a="$ADD_TPS" -v s="$SECONDS" 'BEGIN{printf "%.4f", a*s}')
ADDITIONAL_TX_ROUND=$(awk -v a="$ADD_TPS" -v s="$SECONDS" 'BEGIN{printf "%.0f", a*s}')
CAPACITY_TX_EXACT=$(awk -v a="$TOTAL_CAPACITY" -v s="$SECONDS" 'BEGIN{printf "%.4f", a*s}')
CAPACITY_TX_ROUND=$(awk -v a="$TOTAL_CAPACITY" -v s="$SECONDS" 'BEGIN{printf "%.0f", a*s}')

# Extra pods needed
EXTRA_PODS=$(awk -v req="$REQUIRED_PODS" -v cur="$CURRENT_PODS" 'BEGIN{r=req-cur; if(r<0) r=0; print r}')

# If MAX_PODS provided, check feasibility and compute needed TPS per pod to fit MAX_PODS
SCALING_BLOCKED=false
if [[ -n "$MAX_PODS" ]]; then
    SCALING_BLOCKED=$(awk -v req="$REQUIRED_PODS" -v max="$MAX_PODS" 'BEGIN{print (req>max)?"true":"false"}')
    if [[ "$SCALING_BLOCKED" == "true" ]]; then
        # needed TPS per pod to fit within MAX_PODS = ceil? we compute required TPS per pod (decimal)
        NEEDED_TPS_PER_POD=$(awk -v add="$ADD_TPS" -v max="$MAX_PODS" 'BEGIN{ if(max==0){print "inf"; exit} printf "%.2f", add/max }')
    fi
fi

# --- Output ---
cat <<EOF

==================== RESULTS =====================
INPUTS:
  Additional TPS         : $ADD_TPS
  TPS per Pod            : $TPS_PER_POD
  Current Pods Deployed  : $CURRENT_PODS
  Time Window Selected   : $LABEL ($SECONDS seconds)

FORMULAS:
  Total Capacity (TPS)      = TPS per Pod × Current Pods
                            = $TPS_PER_POD × $CURRENT_PODS
  Pods Required             = ceil( Additional TPS ÷ TPS per Pod )
                            = ceil( $ADD_TPS ÷ $TPS_PER_POD )
  Utilization (%)           = ( Additional TPS ÷ Total Capacity ) × 100
                            = ( $ADD_TPS ÷ $TOTAL_CAPACITY ) × 100
  Projected Additional TX   = Additional TPS × Seconds in Window
                            = $ADD_TPS × $SECONDS
  Total Capacity TX         = Total Capacity (TPS) × Seconds in Window
                            = $TOTAL_CAPACITY × $SECONDS

RESULTS:
  Total Capacity (TPS)      : $TOTAL_CAPACITY
  Pods Required             : $REQUIRED_PODS
  Additional Pods Needed    : $EXTRA_PODS
  Utilization of Capacity   : $UTILIZATION %
  Projected Additional TX   : $ADDITIONAL_TX_EXACT (≈ $ADDITIONAL_TX_ROUND rounded) transactions in $LABEL
  Total Capacity TX         : $CAPACITY_TX_EXACT (≈ $CAPACITY_TX_ROUND rounded) transactions in $LABEL
==================================================

EOF

# --- Recommendations (auto-compute) ---
if [[ "$REQUIRED_PODS" -le "$CURRENT_PODS" ]]; then
    echo "✅ Current deployment can handle the additional traffic (no scale required)."
else
    echo "- Current deployment CANNOT handle the additional traffic."
    echo "- At least $REQUIRED_PODS pods are required."
    echo "- Additional Pods Needed: $EXTRA_PODS"
    echo "--------------------------------------------------"
    echo "RECOMMENDATIONS:"
    echo "1) Increase HPA maxReplicas to at least $REQUIRED_PODS to allow pod scaling."
    echo "2) Verify Karpenter provisioner configuration:"
    echo "   - Ensure provisioner 'limits.resources' (cpu/memory) allow required capacity."
    echo "   - Ensure 'requirements' don't constrain instance types/zones needed for scale-up."
    echo "   - Tune 'consolidation' / 'TTLSecondsAfterEmpty' for faster recovery after bursts."
    echo "3) Ensure namespace ResourceQuota permits scheduling $REQUIRED_PODS pods."
    echo "4) If scaling is blocked or cost-prohibitive, consider optimizing the service to increase TPS per pod."
fi

if [[ -n "$MAX_PODS" && "$SCALING_BLOCKED" == "true" ]]; then
    echo
    echo "🚨 ALERT: Cluster/namespace pod limit ($MAX_PODS) is LOWER than required pods ($REQUIRED_PODS)."
    echo "ACTION OPTIONS:"
    echo "• Increase Karpenter provisioner limits or ResourceQuota to allow more pods."
    echo "• OR improve service efficiency to reach at least $NEEDED_TPS_PER_POD TPS per pod."
    echo "  Needed TPS per Pod  = Additional TPS ÷ Max Allowed Pods  = $NEEDED_TPS_PER_POD"
fi

exit 0
