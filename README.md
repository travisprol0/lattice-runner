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
# optional — freeze the image (default is floating `latest`)
# GITHUB_RUNNER_IMAGE_TAG=2.338.2
# GITHUB_RUNNER_IMAGE_TAG=ubuntu-noble
```

## Start

```bash
chmod +x up.sh   # once
./up.sh
```

That runs `docker compose pull` then `docker compose up -d --force-recreate`. Containers use `restart: unless-stopped`, so they come back after host reboot or process exit until you stop them.

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

## Keeping runners current (not zero-ops forever)

GitHub requires container runners that use `--disableupdate` to be updated **within about 30 days** of a new Actions runner release. There is no durable “set once, never touch again” path.

This project follows the upstream container pattern:

1. Image defaults to floating `myoung34/github-runner:latest` (myoung34 rebuilds it nightly / on merges; version tags track [actions/runner](https://github.com/actions/runner/tags)).
2. `DISABLE_AUTO_UPDATE=true` — GitHub’s container guidance; in-container auto-update does not persist across restarts.
3. `pull_policy: always` + `./up.sh` pulls and recreates so you get the current `latest` binary.

**Ops cadence:** run `./up.sh` at least every few weeks (or wire a cron/systemd timer that does the same). If you pin `GITHUB_RUNNER_IMAGE_TAG` to a version, you must bump that pin yourself before GitHub deprecates it.

## Notes

- `CONFIGURED_ACTIONS_RUNNER_FILES_DIR` persists registration files only (not `bin/`). The runner binary comes from the image.
- `DISABLE_AUTOMATIC_DEREGISTRATION=true` is required with reusage.
- `network_mode: host` — runners use the host network stack.
- `docker compose down -v` wipes registration/caches; not needed for a normal image upgrade.
