#!/usr/bin/env bash
# Delete the kind cluster created by this project. Only ever touches the
# cluster named in kind-config.yaml ("colocation"); asks for confirmation.
# Usage: ./delete-cluster.sh [-y]
set -euo pipefail
NAME="colocation"

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  echo "kind cluster '$NAME' not found, nothing to delete"
  exit 0
fi

if [[ "${1:-}" != "-y" ]]; then
  read -r -p "Delete kind cluster '$NAME' (all its node containers)? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; exit 1; }
fi
kind delete cluster --name "$NAME"
