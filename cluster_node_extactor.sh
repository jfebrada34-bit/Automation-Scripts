#!/bin/bash

# Extract and format Node, InstanceType, and RootDisk in GB
echo -e "Node\tInstanceType\tRootDisk(GB)"

kubectl get nodes -o json 2>/dev/null | jq -r '
  .items[] |
  {
    name: .metadata.name,
    type: .metadata.labels["node.kubernetes.io/instance-type"],
    disk: .status.capacity["ephemeral-storage"]
  } |
  .disk as $disk |
  {
    name: .name,
    type: .type,
    gb: (
      ( ($disk | gsub("Ki";"") | tonumber) / (1024*1024) )
      | floor
    )
  } |
  [ .name, .type, .gb ] | @tsv' | column -t
