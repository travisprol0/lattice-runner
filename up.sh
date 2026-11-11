#!/usr/bin/env bash
# Idempotent runner bring-up. Prefer: bash up.sh
#
# Default: ensure containers are running. Never --force-recreate (that kills a live
# GitHub session while CONFIGURED_ACTIONS_RUNNER_FILES_DIR reuses the same runner
# identity → "A session for this runner already exists").
#
# Image refresh: bash up.sh --upgrade
#   pull → stop → wait for GitHub session release → up -d
#   (actions/runner#3624: instant restart with the same name can reset cleanup)
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

TAG="${GITHUB_RUNNER_IMAGE_TAG:-ubuntu-noble}"
IMAGE="myoung34/github-runner:${TAG}"
# GitHub holds stale sessions after an ungraceful kill; 90s is a practical floor.
SESSION_WAIT="${SESSION_WAIT:-90}"

usage() {
  echo "Usage: bash up.sh [--upgrade] [--help]" >&2
  echo "  (default)   Ensure runners are up; do not recreate healthy containers." >&2
  echo "  --upgrade   Pull image; if changed, stop, wait ${SESSION_WAIT}s, then start." >&2
}

cmd="${1:-}"
case "$cmd" in
  -h|--help)
    usage
    exit 0
    ;;
  --upgrade)
    echo "Pulling ${IMAGE}..."
    docker compose pull

    running="$(docker compose ps -q 2>/dev/null || true)"
    if [[ -z "${running}" ]]; then
      docker compose up -d
      docker compose ps
      exit 0
    fi

    wanted="$(docker image inspect -f '{{.Id}}' "${IMAGE}" 2>/dev/null || true)"
    need_restart=0
    if [[ -n "${wanted}" ]]; then
      while read -r cid; do
        [[ -z "${cid}" ]] && continue
        cur="$(docker inspect -f '{{.Image}}' "${cid}")"
        if [[ "${cur}" != "${wanted}" ]]; then
          need_restart=1
          break
        fi
      done <<< "${running}"
    else
      need_restart=1
    fi

    if [[ "${need_restart}" -eq 0 ]]; then
      echo "Already on current ${IMAGE}; leaving containers alone."
      docker compose up -d --no-recreate
      docker compose ps
      exit 0
    fi

    echo "New image available — graceful stop, wait ${SESSION_WAIT}s for session release, then start."
    docker compose stop
    sleep "${SESSION_WAIT}"
    docker compose up -d
    docker compose ps
    ;;
  "")
    # Create missing containers; never recreate running ones.
    docker compose up -d --no-recreate
    docker compose ps
    ;;
  *)
    usage
    exit 1
    ;;
esac
