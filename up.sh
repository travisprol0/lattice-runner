#!/usr/bin/env bash
# Pull the current image tag (default: latest), then start detached.
# Containers stay up via restart: unless-stopped until you `docker compose stop`.
# Re-run this periodically (GitHub: update within ~30 days of a new runner release).
set -u
cd "$(dirname "$0")"

docker compose pull
docker compose up -d --force-recreate
