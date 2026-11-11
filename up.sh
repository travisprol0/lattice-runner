#!/usr/bin/env bash
# Build and start runners detached; containers stay up via restart: unless-stopped
# until you `docker compose stop`.
set -u
cd "$(dirname "$0")"

docker compose up --build -d
