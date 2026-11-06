#!/usr/bin/env bash
# Deploy Online Boutique (official release manifest, unmodified) into a namespace.
# Usage: ./deploy.sh [NAMESPACE]        (default: boutique)
#   env MANIFEST=... to override the manifest path
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${1:-boutique}"
MANIFEST="${MANIFEST:-$HERE/../microservices-demo/release/kubernetes-manifests.yaml}"

echo "context: $(kubectl config current-context)  namespace: $NS"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
kubectl apply -n "$NS" -f "$MANIFEST"

echo "Waiting for app deployments to become available (timeout 10m)..."
kubectl -n "$NS" wait --for=condition=available deployment \
  -l 'app!=loadgenerator' --timeout=600s
echo "Waiting for loadgenerator (timeout 3m)..."
if ! kubectl -n "$NS" wait --for=condition=available deployment/loadgenerator --timeout=180s; then
  echo "WARNING: loadgenerator not available; check:" >&2
  echo "  kubectl -n $NS describe pod -l app=loadgenerator" >&2
fi
kubectl -n "$NS" get pods -o wide

echo
echo "Access the frontend with:"
echo "  kubectl -n $NS port-forward svc/frontend 8080:80"
