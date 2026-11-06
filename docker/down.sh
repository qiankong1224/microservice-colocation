#!/usr/bin/env bash
# Stop and remove all Online Boutique containers/networks (including the load profile).
# Images are kept so the next start is fast; pass --rmi to also remove them.
set -euo pipefail
cd "$(dirname "$0")"

EXTRA=()
if [[ "${1:-}" == "--rmi" ]]; then
  EXTRA+=(--rmi all)
fi
docker compose --profile load -f docker-compose.yml down --remove-orphans "${EXTRA[@]}"
