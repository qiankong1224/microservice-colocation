#!/usr/bin/env bash
# Remove Online Boutique by deleting its namespace. Does NOT delete the cluster
# (use ./delete-cluster.sh for that).
# Usage: ./teardown.sh [NAMESPACE]      (default: boutique)
set -euo pipefail
NS="${1:-boutique}"

echo "context: $(kubectl config current-context)  namespace: $NS"
if kubectl get namespace "$NS" >/dev/null 2>&1; then
  kubectl delete namespace "$NS" --wait=true
else
  echo "namespace $NS not found, nothing to delete"
fi
