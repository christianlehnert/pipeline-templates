#!/usr/bin/env bash
# Wait until URL returns HTTP status 200.
#
# Usage: wait-for-health.sh URL [TIMEOUT_SECONDS]
set -euo pipefail

url="${1:?usage: wait-for-health.sh URL [TIMEOUT_SECONDS]}"
timeout="${2:-60}"
deadline=$((SECONDS + timeout))
status="none"

while true; do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' "$url" || true)"
  if [ "$status" = "200" ]; then
    echo "$url returned 200"
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::$url did not return 200 within ${timeout}s (last status: ${status})"
    exit 1
  fi
  sleep 2
done
