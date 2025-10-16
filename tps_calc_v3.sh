#!/bin/bash
# ================================================================
# TPS Capacity Checker v3
# ------------------------------------------------
# Calculates required Pods, HPA settings, Node sizing,
# total CPU cores, and cost estimates from transaction load.
#
# Requirements:
#   • bash 4+
#   • bc (brew install bc  OR  apt-get install bc)
# ================================================================

echo "========== TPS Capacity Checker =========="

# ----- User Inputs -----
read -p "Is Istio enabled? (y/n) [y]: " istio
istio=${istio:-y}

read -p "Do you want to calculate TPS from total transactions? (y/n) [y]: " calc_tps
calc_tps=${calc_tps:-y}

if [[ "$calc_tps" =~ ^[Yy]$ ]]; then
  read -p "Enter total number of transactions (e.g. monthly total or total for the period) [0]: " total_txn
  total_txn=${total_txn:-0}

  read -p "Enter time period in days for that total [30]: " days
  days=${days:-30}

  # TPS formulas
  tps_24x7=$(echo "scale=6; $total_txn / ($days*24*60*60)" | bc)
  tps_8hr=$(echo "scale=6; $total_txn / ($days*8*60*60)" | bc)

  echo
  echo "💡 TPS formula reference"
  echo "   24×7  => total / (days × 24h × 60m × 60s)"
  echo "   8-hour => total / (days × 8h × 60m × 60s)"
  printf "   => 24×7 derived:  %.6f TPS/sec  |  %.2f TPS/min  |  %.2f TPS/hr\n" \
         "$tps_24x7" "$(echo "$tps_24x7*60" | bc)" "$(echo "$tps_24x7*3600" | bc)"
  printf "   => 8-hour derived: %.6f TPS/sec  |  %.2f TPS/min  |  %.2f TPS/hr\n" \
         "$tps_8hr" "$(echo "$tps_8hr*60" | bc)" "$(echo "$tps_8hr*3600" | bc)"

  read -p "Use 24×7 TPS [1] or 8-hour TPS [2] [1]: " mode
  mode=${mode:-1}
  if [[ "$mode" == "2" ]]; then
    tps=$tps_8hr
  else
    tps=$tps_24x7
  fi
else
  read -p "Enter required TPS per second [0]: " tps
  tps=${tps:-0}
fi

read -p "Enter Tested TPS each pod can handle [400]: " pod_tps
pod_tps=${pod_tps:-400}

read -p "Enter node CPU capacity (mCPU) [4000]: " node_cpu
node_cpu=${node_cpu:-4000}

read -p "Enter node Memory capacity (Mi) [16384]: " node_mem
node_mem=${node_mem:-16384}

read -p "Enter HPA burst factor (default 2.0): " burst
burst=${burst:-2.0}

# ----- Core Calculations -----
# Minimum pods (ceiling)
pods_needed=$(echo "scale=0; if ($tps/$pod_tps > 0) ((($tps/$pod_tps)+0.999)/1) else 0" | bc)
if [[ -z "$pods_needed" || "$pods_needed" -lt 1 ]]; then
  pods_needed=1
fi

hpa_min=$pods_needed
hpa_max=$(echo "scale=0; ($pods_needed * $burst)+0.999" | bc)

# Pod Requests
cpu_req_m=250
cpu_buf_m=325   # +30% buffer
cpu_lim_m=1000
mem_req_mi=2000
mem_lim_mi=4000

# Totals
total_cpu_req=$(echo "scale=2; ($pods_needed * $cpu_req_m) / 1000" | bc)
total_cpu_buf=$(echo "scale=2; ($pods_needed * $cpu_buf_m) / 1000" | bc)
total_mem_req_gi=$(echo "scale=2; ($pods_needed * $mem_req_mi) / 1024" | bc)

# Nodes needed (CPU vs Memory)
nodes_cpu=$(echo "scale=0; (($pods_needed * $cpu_req_m) / $node_cpu) + 0.999" | bc)
nodes_mem=$(echo "scale=0; (($pods_needed * $mem_req_mi) / $node_mem) + 0.999" | bc)

if [[ "$nodes_cpu" -gt "$nodes_mem" ]]; then
  nodes=$nodes_cpu
  limiting="CPU"
else
  nodes=$nodes_mem
  limiting="Memory"
fi

# Cost estimate (per core)
cost_low=$(echo "scale=2; $total_cpu_req * 106.88" | bc)
cost_high=$(echo "scale=2; $total_cpu_req * 285.02" | bc)

# ----- Output -----
echo
echo "📊 Production Cluster Sizing Report"
echo "--------------------------------------------------"
echo "Traffic Forecast (mode: $([[ "$mode" == "2" ]] && echo "8-hour" || echo "24×7"))"
printf "• Required TPS (per second) : ~%.2f TPS\n" "$tps"
printf "• Required TPS (per minute) : ~%.2f TPS\n" "$(echo "$tps*60" | bc)"
printf "• Required TPS (per hour)   : ~%.2f TPS\n" "$(echo "$tps*3600" | bc)"
printf "• Each pod can handle       : %.2f TPS/pod\n" "$pod_tps"
printf "• ➜ Minimum pods needed     : %s pods\n" "$pods_needed"

echo
echo "Horizontal Pod Autoscaler (HPA)"
printf "• HPA minimum pods          : %s\n" "$hpa_min"
printf "• HPA maximum pods (%.1fx)  : %s (burst capacity)\n" "$burst" "$hpa_max"
echo "• CPU trigger threshold     : 60%"

echo
echo "Pod request / limit"
printf "• CPU request (base)        : %dm\n" "$cpu_req_m"
printf "• CPU request (+30%% buffer) : %dm (safety margin)\n" "$cpu_buf_m"
printf "• CPU limit                 : %dm\n" "$cpu_lim_m"
printf "• Memory request / limit    : %dMi / %dMi\n" "$mem_req_mi" "$mem_lim_mi"
printf "• Istio sidecar             : %s\n" "$([[ "$istio" =~ ^[Yy]$ ]] && echo "Yes" || echo "No")"

echo
echo "Node Sizing Estimate"
printf "• Node CPU Capacity         : %dm\n" "$node_cpu"
printf "• Node Memory Capacity      : %dMi\n" "$node_mem"
printf "• ➜ Estimated Nodes         : %s  (limited by **%s**)\n" "$nodes" "$limiting"

echo
echo "Cost Estimate (based on typical cloud rates)"
printf "• Total CPU (requests)      : %.2f cores\n" "$total_cpu_req"
printf "• Total CPU (+30%% buffer)   : %.2f cores\n" "$total_cpu_buf"
printf "• Estimated Monthly Cost    : \$%.2f – \$%.2f\n" "$cost_low" "$cost_high"

echo
printf "%-10s %-10s %-5s %-20s %-7s %-7s %-7s %-7s %-6s %-6s %-7s\n" \
"Cluster" "Namespace" "Pods" "Pod Specs" "CPUReq" "CPULim" "MemReq" "MemLim" "HPAmin" "HPAmax" "CPUTrig"
printf "%-10s %-10s %-5s %-20s %-7s %-7s %-7s %-7s %-6s %-6s %-7s\n" \
"default" "default" "$pods_needed" "1000mCPU/4000Mi" \
"${cpu_req_m}m" "${cpu_lim_m}m" "${mem_req_mi}Mi" "${mem_lim_mi}Mi" \
"$hpa_min" "$hpa_max" "60%"
echo "--------------------------------------------------"
