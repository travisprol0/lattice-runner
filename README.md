# lattice-runner

Self-hosted GitHub Actions runners for [travisprol0/lattice-log](https://github.com/travisprol0/lattice-log), via Compose + [myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner).

Four runners (`talos-1` … `talos-4`) share the `talos` label (`runs-on: [self-hosted, talos]` or `talos-N`).

## Setup

```bash
cp .env.example .env
# edit .env → GITHUB_RUNNER_TOKEN=...
```

Token scopes: see [myoung34 Usage wiki — Token Scope](https://github.com/myoung34/docker-github-actions-runner/wiki/Usage#token-scope) (`repo` for repo runners).

## Daily command (idempotent)

```bash
bash up.sh
```

That is `docker compose up -d --no-recreate`: starts missing containers, **never** kills healthy ones.

Do **not** use `./up.sh` unless you have run `chmod +x up.sh` once; `bash up.sh` always works.

## Image upgrades (every few weeks)

GitHub requires container runners with `--disableupdate` to be updated within ~30 days of a new release ([changelog](https://github.blog/changelog/2022-02-01-github-actions-self-hosted-runners-can-now-disable-automatic-updates/)). myoung34 rebuilds `latest` nightly; in-container auto-update does not persist across restarts ([#251](https://github.com/myoung34/docker-github-actions-runner/issues/251)).

```bash
bash up.sh --upgrade
```

Pulls the image; if the digest changed: `compose stop` → wait (default 90s) → `compose up -d`. Instant recreate with the same `RUNNER_NAME` causes **“A session for this runner already exists”** ([actions/runner#3624](https://github.com/actions/runner/issues/3624)).

## Stop

```bash
docker compose stop
```

```bash
docker compose down          # keep volumes (registration + caches)
docker compose down -v       # wipe registration/caches — rare
```

## Runners

| Service  | RUNNER_NAME | Labels           | Data volume    |
|----------|-------------|------------------|----------------|
| runner-1 | talos-1     | talos, talos-1   | runner-1-data  |
| runner-2 | talos-2     | talos, talos-2   | runner-2-data  |
| runner-3 | talos-3     | talos, talos-3   | runner-3-data  |
| runner-4 | talos-4     | talos, talos-4   | runner-4-data  |

Each has a **unique stable** `RUNNER_NAME` and its own data volume (required: runners on one host must not share `RUNNER_WORKDIR` — [myoung34 README](https://github.com/myoung34/docker-github-actions-runner/blob/master/README.md)).

## Env (must match upstream)

| Variable | Value | Why |
|----------|--------|-----|
| `CONFIGURED_ACTIONS_RUNNER_FILES_DIR` | `/tmp/runner` | Persist registration ([README](https://github.com/myoung34/docker-github-actions-runner/blob/master/README.md); wiki Reusage) |
| `DISABLE_AUTOMATIC_DEREGISTRATION` | `true` | Required with reusage or entrypoint exits |
| `DISABLE_AUTO_UPDATE` | `true` | Container path; any value is truthy |
| Image | `…:latest` (or pin via `GITHUB_RUNNER_IMAGE_TAG`) | Floating tag + `bash up.sh --upgrade` |

## Recovery: session Conflict right now

If logs say `A session for this runner already exists` / `Conflict`:

```bash
docker compose stop
sleep 90
# If still conflicting after start, wait longer (sessions can linger several minutes):
# sleep 300
bash up.sh
docker compose logs -f --tail=80
```

Expect `Listening for Jobs` without Conflict. Do **not** `--force-recreate` in a loop — that resets GitHub’s session cleanup timer.
