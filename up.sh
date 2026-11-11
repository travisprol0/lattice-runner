#!/usr/bin/env bash
# Keep `docker compose up --build` running until you stop it (Ctrl-C).
set -u
cd "$(dirname "$0")"

trap 'echo; echo "Stopped."; exit 0' INT TERM

while true; do
  docker compose up --build
  status=$?
  # 130/143 = interrupted; treat as intentional stop
  if [[ "$status" -eq 130 || "$status" -eq 143 ]]; then
    exit 0
  fi
  echo "docker compose exited ($status); restarting in 3s (Ctrl-C to stop)..." >&2
  sleep 3
done
