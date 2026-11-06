#!/usr/bin/env bash
# Start Online Boutique with docker compose.
# Usage: ./up.sh [--load]     (--load also starts the loadgenerator profile)
set -euo pipefail
cd "$(dirname "$0")"

ARGS=()
if [[ "${1:-}" == "--load" ]]; then
  ARGS+=(--profile load)
fi

# Pull only missing images, with retries (registry access via local proxy can time out).
for img in $(docker compose "${ARGS[@]}" -f docker-compose.yml config --images | sort -u); do
  docker image inspect "$img" >/dev/null 2>&1 && continue
  for t in 1 2 3 4 5; do
    if docker pull -q "$img" >/dev/null; then echo "pulled $img"; break; fi
    [[ $t -eq 5 ]] && { echo "failed to pull $img" >&2; exit 1; }
    echo "retry $t pulling $img ..."; sleep 5
  done
done

docker compose "${ARGS[@]}" -f docker-compose.yml up -d --pull never
docker compose "${ARGS[@]}" -f docker-compose.yml ps

PORT=$(docker compose -f docker-compose.yml port frontend 8080 | awk -F: '{print $NF}')
echo "Waiting for frontend on http://localhost:${PORT}/ ..."
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" || true)
  if [[ "$code" == "200" ]]; then
    echo "frontend ready (HTTP 200) after ${i} tries"
    exit 0
  fi
  sleep 2
done
echo "frontend not ready; check: docker compose logs frontend" >&2
exit 1
