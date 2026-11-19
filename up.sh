#!/usr/bin/env bash
# Idempotent runner bring-up across hosts. Prefer: bash up.sh
#
# Hosts (see HOST_* below): talos = local Docker, hermes = remote via the `hermes`
# Docker context (ssh://twelvetwo@hermes; created by scripts/hermes-prep.sh).
#
# Default: ensure containers are running. Never --force-recreate (that kills a live
# GitHub session while CONFIGURED_ACTIONS_RUNNER_FILES_DIR reuses the same runner
# identity → "A session for this runner already exists").
#
# Never `docker compose down -v` as a routine fix — wiping runner-*-data leaves
# offline duplicate registrations on GitHub. Prune with
# scripts/prune_offline_runners.py instead.
#
# Image refresh: bash up.sh --upgrade
#   pull → stop → wait for GitHub session release → up -d   (per host)
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
# Keep the project name stable per directory so existing volumes (lattice-runner_*) are reused.
PROJECT="$(basename "$PWD")"

# host → docker context ("" = current/local) and compose file
declare -A HOST_CTX=( [talos]="" [hermes]="hermes" )
declare -A HOST_FILE=( [talos]="docker-compose.yml" [hermes]="docker-compose.hermes.yml" )
ALL_HOSTS="${HOSTS:-talos hermes}"

usage() {
  echo "Usage: bash up.sh [--upgrade] [--host talos|hermes] [--help]" >&2
  echo "  (default)   Ensure runners are up on all hosts (${ALL_HOSTS}); do not recreate healthy containers." >&2
  echo "  --upgrade   Pull image; if changed, stop, wait ${SESSION_WAIT}s, then start (per host)." >&2
  echo "  --host H    Only act on host H (repeatable). Env HOSTS=\"talos hermes\" sets the default." >&2
}

run_host() {
  local host="$1" ctx="${HOST_CTX[$1]}" file="${HOST_FILE[$1]}" upgrade="$2"
  (
    if [[ -n "${ctx}" ]]; then
      if ! docker context inspect "${ctx}" >/dev/null 2>&1; then
        echo "[${host}] docker context '${ctx}' missing — run: bash scripts/hermes-prep.sh" >&2
        exit 1
      fi
      export DOCKER_CONTEXT="${ctx}"
    fi
    dc() { docker compose -p "${PROJECT}" -f "${file}" "$@"; }

    echo "=== ${host} ==="
    if [[ "${upgrade}" -eq 0 ]]; then
      dc up -d --no-recreate
      dc ps
      exit 0
    fi

    echo "Pulling ${IMAGE}..."
    dc pull

    running="$(dc ps -q 2>/dev/null || true)"
    if [[ -z "${running}" ]]; then
      dc up -d
      dc ps
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
      dc up -d --no-recreate
      dc ps
      exit 0
    fi

    echo "New image available — graceful stop, wait ${SESSION_WAIT}s for session release, then start."
    dc stop
    sleep "${SESSION_WAIT}"
    dc up -d
    dc ps
  )
}

upgrade=0
selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --upgrade) upgrade=1 ;;
    --host)
      shift
      [[ -n "${1:-}" && -n "${HOST_FILE[$1]:-}" ]] || { usage; exit 1; }
      selected+=("$1")
      ;;
    *) usage; exit 1 ;;
  esac
  shift
done
if [[ ${#selected[@]} -eq 0 ]]; then
  read -r -a selected <<< "${ALL_HOSTS}"
fi

# One unreachable host must not block the others; report failures at the end.
failed=()
for h in "${selected[@]}"; do
  set +e
  run_host "$h" "${upgrade}"
  st=$?
  set -e
  [[ $st -eq 0 ]] || failed+=("$h")
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED hosts: ${failed[*]}" >&2
  exit 1
fi
