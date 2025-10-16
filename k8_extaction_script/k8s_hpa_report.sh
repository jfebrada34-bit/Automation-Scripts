#!/bin/bash
# Script: k8s_hpa_report.sh
# Description:
#   Generates a full CSV report of Kubernetes Deployments and HPA metrics,
#   while printing only the deployment names to the terminal.

OUTPUT_FILE="wc-v4-k8s_hpa_full_report.csv"

# ✅ Detect Cluster Name
CLUSTER_NAME=$(kubectl config current-context 2>/dev/null | awk -F'@' '{print $NF}')

# ✅ Optional namespace argument
if [ -n "$1" ]; then
  TARGET_NAMESPACES=("$1")
  echo "🔄 Generating Kubernetes HPA report for namespace: $1 ... please wait."
else
  TARGET_NAMESPACES=($(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
  echo "🔄 Generating Kubernetes HPA report for ALL namespaces... please wait."
fi

# ✅ CSV Header
HEADER="Cluster,Namespace,Deployment,Type,CreationTimestamp,Desired Replicas,Available Replicas,HPA Name,HPA Min Pods,HPA Max Pods,HPA Current Replicas,HPA Target CPU (%),HPA Current CPU (%),HPA Target Memory (%),HPA Current Memory (%),Current Running Pods,CPU Requests (m),CPU Limits (m),Memory Requests (Mi),Memory Limits (Mi),Current CPU (m),Current Memory (Mi)"
echo "$HEADER" > "$OUTPUT_FILE"

# ✅ Loop through namespaces and deployments
for ns in "${TARGET_NAMESPACES[@]}"; do
  for deploy in $(kubectl get deploy -n "$ns" --no-headers -o custom-columns=":metadata.name" 2>/dev/null); do

    # --- Deployment details ---
    CREATION_TS=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    DESIRED_REPLICAS=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    AVAILABLE_REPLICAS=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)

    # --- HPA details ---
    HPA_NAME=$(kubectl get hpa -n "$ns" --no-headers --ignore-not-found 2>/dev/null | grep "^$deploy " | awk '{print $1}')
    if [ -n "$HPA_NAME" ]; then
      HPA_MIN=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
      HPA_MAX=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
      HPA_CURR=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
      HPA_CPU_TARGET=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.spec.metrics[?(@.resource.name=="cpu")].resource.target.averageUtilization}' 2>/dev/null)
      HPA_CPU_CURR=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' 2>/dev/null)
      HPA_MEM_TARGET=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.spec.metrics[?(@.resource.name=="memory")].resource.target.averageUtilization}' 2>/dev/null)
      HPA_MEM_CURR=$(kubectl get hpa "$HPA_NAME" -n "$ns" -o jsonpath='{.status.currentMetrics[?(@.resource.name=="memory")].resource.current.averageUtilization}' 2>/dev/null)
      TYPE="HPA"
    else
      HPA_NAME="N/A"
      HPA_MIN="N/A"
      HPA_MAX="N/A"
      HPA_CURR="N/A"
      HPA_CPU_TARGET="N/A"
      HPA_CPU_CURR="N/A"
      HPA_MEM_TARGET="N/A"
      HPA_MEM_CURR="N/A"
      TYPE="Deployment"
    fi

    # --- Running Pods ---
    RUNNING_PODS=$(kubectl get pods -n "$ns" -l app="$deploy" \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    # --- Resource Requests & Limits ---
    CPU_REQ=$(kubectl get deploy "$deploy" -n "$ns" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}' 2>/dev/null \
      | awk '{v=$1; if(v=="") v=0; sum+=v} END {print sum+0}')
    CPU_LIM=$(kubectl get deploy "$deploy" -n "$ns" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.resources.limits.cpu}{"\n"}{end}' 2>/dev/null \
      | awk '{v=$1; if(v=="") v=0; sum+=v} END {print sum+0}')
    MEM_REQ=$(kubectl get deploy "$deploy" -n "$ns" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.resources.requests.memory}{"\n"}{end}' 2>/dev/null \
      | awk '{if($1~/Mi/){gsub("Mi","",$1);sum+=$1}else if($1~/Gi/){gsub("Gi","",$1);sum+=($1*1024)}} END {print sum+0}')
    MEM_LIM=$(kubectl get deploy "$deploy" -n "$ns" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.resources.limits.memory}{"\n"}{end}' 2>/dev/null \
      | awk '{if($1~/Mi/){gsub("Mi","",$1);sum+=$1}else if($1~/Gi/){gsub("Gi","",$1);sum+=($1*1024)}} END {print sum+0}')

    # --- Live CPU & Memory Usage (kubectl top) ---
    CURRENT_CPU=$(kubectl top pod -n "$ns" -l app="$deploy" --no-headers 2>/dev/null \
      | awk '{gsub("m","",$2); if($2=="") $2=0; sum+=$2} END {print sum+0}')
    CURRENT_MEM=$(kubectl top pod -n "$ns" -l app="$deploy" --no-headers 2>/dev/null \
      | awk '{if($3~/Mi/){gsub("Mi","",$3);sum+=$3}else if($3~/Gi/){gsub("Gi","",$3);sum+=($3*1024)}} END {print sum+0}')

    # --- Append to CSV ---
    ROW="$CLUSTER_NAME,$ns,$deploy,$TYPE,$CREATION_TS,$DESIRED_REPLICAS,$AVAILABLE_REPLICAS,$HPA_NAME,$HPA_MIN,$HPA_MAX,$HPA_CURR,$HPA_CPU_TARGET,$HPA_CPU_CURR,$HPA_MEM_TARGET,$HPA_MEM_CURR,$RUNNING_PODS,$CPU_REQ,$CPU_LIM,$MEM_REQ,$MEM_LIM,$CURRENT_CPU,$CURRENT_MEM"
    echo "$ROW" >> "$OUTPUT_FILE"

    # --- Terminal Output (Deployment name only) ---
    echo "$deploy"

  done
done

echo "✅ Full report saved to $OUTPUT_FILE"
