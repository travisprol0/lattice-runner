# lattice-runner

Self-hosted GitHub Actions runners for [travisprol0/lattice-log](https://github.com/travisprol0/lattice-log), run as Docker containers via Compose.

Four runners (`talos-1` … `talos-4`) share the `talos` label so workflows can target `runs-on: [self-hosted, talos]` or a specific runner with `talos-N`.

## Prerequisites

- Docker and Docker Compose
- A GitHub personal access token with permission to register runners on the repo (classic PAT: `repo` scope, or a fine-grained token that can manage Actions runners)

## Setup

Create a `.env` in this directory (gitignored):

```bash
GITHUB_RUNNER_TOKEN=ghp_...
# optional — pin the runner image
# GITHUB_RUNNER_IMAGE_TAG=latest
```

## Start

```bash
chmod +x up.sh   # once
./up.sh
```

That runs `docker compose up --build -d`. Containers use `restart: unless-stopped`, so they come back after host reboot or process exit until you stop them.

Equivalent:

```bash
docker compose up --build -d
```

## Stop

```bash
docker compose stop
```

To remove containers (volumes keep registration and caches):

```bash
docker compose down
```

## Runners

| Service   | Name    | Labels          |
|-----------|---------|-----------------|
| runner-1  | talos-1 | `talos`, `talos-1` |
| runner-2  | talos-2 | `talos`, `talos-2` |
| runner-3  | talos-3 | `talos`, `talos-3` |
| runner-4  | talos-4 | `talos`, `talos-4` |

Each runner mounts the host Docker socket, so jobs can build/run containers. Registration and tool caches live in named volumes so restarts do not re-register and wipe caches.

## Notes

- Leave `DISABLE_AUTO_UPDATE` unset — any value is truthy on this image and can pin a deprecated runner that GitHub rejects.
- `CONFIGURED_ACTIONS_RUNNER_FILES_DIR` points at the data volume so config survives restarts (avoids re-register crash loops).
- `network_mode: host` — runners use the host network stack.
