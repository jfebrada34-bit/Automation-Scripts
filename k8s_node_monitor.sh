#!/bin/bash
# ===============================================
# Kubernetes Cluster Capacity Monitoring Script (CSV Export)
# Using kubectl top (handles both new and old formats)
# ===============================================

export KUBECTL_SUPPRESS_WARNINGS=true   # hide kubeconfig token warnings

OUTPUT_DIR="./k8s_report"
mkdir -p "$OUTPUT_DIR"

NODES_CSV="$OUTPUT_DIR/nodes.csv"
PODS_CSV="$OUTPUT_DIR/pods.csv"

echo "Collecting Kubernetes cluster metrics..."
DATE_NOW=$(date +"%Y-%m-%d %H:%M:%S")

# --------------------------------------------------
# Function to get node metrics safely
# Works if `kubectl top nodes` shows either:
# NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
# or
# NAME CPU(cores) MEMORY(bytes)
# --------------------------------------------------
get_node_metrics () {
    local node=$1
    local line
    line=$(kubectl top nodes --no-headers | awk -v n="$node" '$1==n {print}')

    # Split into array
    read -ra arr <<< "$line"

    # Minimum columns: name cpu mem
    local cpu="N/A" cpuPerc="N/A" mem="N/A" memPerc="N/A"
    if [ ${#arr[@]} -ge 3 ]; then
        cpu="${arr[1]}"
        # if there are 4+ columns check whether 3rd is CPU% or Memory
        if [[ ${#arr[@]} -eq 3 ]]; then
            mem="${arr[2]}"
        elif [[ ${#arr[@]} -eq 4 ]]; then
            mem="${arr[2]}"
            memPerc="${arr[3]}"
        elif [[ ${#arr[@]} -ge 5 ]]; then
            cpuPerc="${arr[2]}"
            mem="${arr[3]}"
            memPerc="${arr[4]}"
        fi
    fi
    echo "$cpu,$cpuPerc,$mem,$memPerc"
}

# --------------------------------------------------
# Function to get pod metrics safely
# --------------------------------------------------
get_pod_metrics () {
    local ns=$1
    local pod=$2
    local line
    line=$(kubectl top pod -n "$ns" "$pod" --no-headers 2>/dev/null)
    read -ra arr <<< "$line"
    local cpu="N/A" mem="N/A"
    if [ ${#arr[@]} -ge 3 ]; then
        cpu="${arr[1]}"
        mem="${arr[2]}"
    fi
    echo "$cpu,$mem"
}

# --- Nodes CSV ---
echo "Node,Status,Roles,Age,Version,CPU_Usage,CPU_Percent,Memory_Usage,Memory_Percent" > "$NODES_CSV"

kubectl get nodes --no-headers \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels."kubernetes\.io/role",AGE:.metadata.creationTimestamp,VERSION:.status.nodeInfo.kubeletVersion |
while read -r node status roles age version; do
    metrics=$(get_node_metrics "$node")
    echo "$node,$status,$roles,$age,$version,$metrics" >> "$NODES_CSV"
done

# --- Pods CSV ---
echo "Namespace,Pod,Status,Age,CPU_Usage,Memory_Usage" > "$PODS_CSV"

kubectl get pods --all-namespaces --no-headers \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp |
while read -r ns pod status age; do
    metrics=$(get_pod_metrics "$ns" "$pod")
    echo "$ns,$pod,$status,$age,$metrics" >> "$PODS_CSV"
done

echo "✅ CSV reports generated:"
echo "  - Nodes: $NODES_CSV"
echo "  - Pods : $PODS_CSV"
