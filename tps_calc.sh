#!/usr/bin/env bash
# ==========================================================
# TPS CAPACITY CHECKER WITH TIME WINDOW + FORMULAS
# ----------------------------------------------------------
# Calculates:
#   - Total TPS capacity of a Kubernetes deployment
#   - Required pods to handle additional traffic
#   - Projected transaction counts over 1 min, 1 hr, or 8 hr
#   - Displays the formulas used for transparency
#   - 30-day monthly transactions (8 hours/day)
#
# REQUIREMENTS:
#   bash, bc
# ==========================================================

validate_number() {
    if ! [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "❌ Error: $2 must be a positive number." >&2
        exit 1
    fi
}

echo "========== TPS Capacity Checker =========="
read -rp "Enter Additional TPS (forecasted traffic): " ADD_TPS
validate_number "$ADD_TPS" "Additional TPS"

read -rp "Enter Tested TPS per Pod: " TPS_PER_POD
validate_number "$TPS_PER_POD" "TPS per Pod"

read -rp "Enter Current Number of Pods: " CURRENT_PODS
validate_number "$CURRENT_PODS" "Current Pods"

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

# ---- Calculations ----
TOTAL_CAPACITY=$(echo "scale=4; $TPS_PER_POD * $CURRENT_PODS" | bc)
# Round up required pods (integer ceiling)
REQUIRED_PODS=$(echo "scale=0; ($ADD_TPS + $TPS_PER_POD - 1) / $TPS_PER_POD" | bc)
UTILIZATION=$(echo "scale=2; ($ADD_TPS / $TOTAL_CAPACITY) * 100" | bc)
ADDITIONAL_TX=$(echo "scale=2; $ADD_TPS * $SECONDS" | bc)
CAPACITY_TX=$(echo "scale=2; $TOTAL_CAPACITY * $SECONDS" | bc)

# 30-day monthly traffic (8-hour daily window)
MONTHLY_TX=$(echo "scale=2; $ADD_TPS * 30 * 8 * 60 * 60" | bc)

# ---- Output ----
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
  30-Day Projected TX       = Additional TPS × 30 days × 8h/day × 60m × 60s
                            = $ADD_TPS × 30 × 8 × 60 × 60

RESULTS:
  Total Capacity (TPS)      : $TOTAL_CAPACITY
  Pods Required             : $REQUIRED_PODS
  Utilization of Capacity   : $UTILIZATION %
  Projected Additional TX   : $ADDITIONAL_TX transactions in $LABEL
  Total Capacity TX         : $CAPACITY_TX transactions in $LABEL
  30-Day Projected TX       : $MONTHLY_TX transactions (8 hours/day)
==================================================

EOF

if (( $(echo "$CURRENT_PODS >= $REQUIRED_PODS" | bc -l) )); then
    echo "✅ Current deployment can handle the additional traffic."
else
    echo "⚠️  Scale up to at least $REQUIRED_PODS pods to handle the additional traffic safely."
fi

exit 0
