#!/usr/bin/env bash
# Start IMAGE, wait until http://127.0.0.1:PORT/HEALTH_PATH returns 200, print the
# container logs on failure and always remove the container.
#
# Environment:
#   IMAGE        image reference (required); references with a digest are pulled first
#   PORT         port inside the container, published on the same host port (default 8080)
#   HEALTH_PATH  health endpoint path (default /health)
#   TIMEOUT      seconds to wait (default 60)
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
PORT="${PORT:-8080}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
TIMEOUT="${TIMEOUT:-60}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
container="smoke-test-$$"

cleanup() {
  docker rm --force "$container" > /dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$IMAGE" == *"@"* ]]; then
  docker pull --quiet "$IMAGE"
fi

docker run --detach --name "$container" --publish "127.0.0.1:${PORT}:${PORT}" "$IMAGE" > /dev/null

if ! bash "$script_dir/wait-for-health.sh" "http://127.0.0.1:${PORT}${HEALTH_PATH}" "$TIMEOUT"; then
  echo "::group::Container logs"
  docker logs "$container" || true
  echo "::endgroup::"
  exit 1
fi
