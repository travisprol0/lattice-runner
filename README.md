# lattice-runner

Self-hosted GitHub Actions runners for [travisprol0/lattice-log](https://github.com/travisprol0/lattice-log), via Compose + [myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner).

Four heavy runners (`talos-1` … `talos-4`) share the `talos` label (`runs-on: [self-hosted, talos]` or `talos-N`); lattice-log runs pytest and Cypress only on those, so at most four heavy jobs run at once on the 4-core / 8-thread host. lattice-log's `build-assets` also runs only on those, because test-backend waits on it and the Node build needs the 8 threads. A fifth runner, `talos-light`, has **no** `talos` label; lattice-log's `talos-turn` gate holds it while it waits for older runs. Light jobs (`runs-on: self-hosted`: quality-gate, docs build, `ci-success`) match every runner, including `talos-1` … `talos-4` and `hermes-1`. GitHub picks any idle one, so a light job can take a heavy slot and delay a heavy job, but it never hangs. CI uses **host** Postgres at `127.0.0.1:5432` on talos (not a job-local `-p 5432:5432` container). Production app stays on Render (https://latticelog.com) with its own DB. stagehand on talos monitors these runners with `GITHUB_REPO=travisprol0/lattice-log`.

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

## Second host: hermes (Docker context, not Swarm)

`hermes` (old MacBook Air) runs `hermes-1` (labels `hermes,hermes-1`) from `docker-compose.hermes.yml`, driven from talos over a Docker context (`ssh://twelvetwo@hermes`). Swarm was rejected: it ignores `network_mode: host` and per-node named volumes don't fit persisted runner registration.

Network: talos `192.168.50.31` (ethernet, static via netplan), hermes `192.168.50.65` (wifi, static via netplan + Asus DHCP reservation). hermes's Broadcom BCM4360 wifi (`14e4:43a0`) needs `bcmwl-kernel-source` and `wpasupplicant` (neither is in Ubuntu Server by default; install over USB tethering or USB ethernet).

One-time prep (from talos; prompts for ssh + sudo passwords):

```bash
bash scripts/hermes-prep.sh   # defaults to 192.168.50.65; override with HERMES_HOST=
```

Then, as always:

```bash
bash up.sh                  # talos + hermes
bash up.sh --host hermes    # one host
bash up.sh --upgrade        # per-host pull/stop/wait/start
```

Every self-hosted runner has the `self-hosted` label, so lattice-log's light jobs (`runs-on: self-hosted`) already land on hermes when it is idle. `runs-on: [self-hosted, hermes]` pins a job to hermes only; lattice-log does not do this, because that job would queue for as long as hermes is offline. Heavy jobs and `build-assets` need host Postgres or the talos CPU, so they use `[self-hosted, talos]` and never land on hermes.

## Stop

```bash
docker compose stop
```

```bash
docker compose down          # keep volumes (registration + caches)
docker compose down -v       # wipe registration/caches — NEVER routine
```

**Do not** `compose down -v` or wipe `runner-*-data` to “fix” a bad session.
`DISABLE_AUTOMATIC_DEREGISTRATION=true` + a wiped volume re-registers a **new**
GitHub runner id under the same `RUNNER_NAME`, leaving offline duplicates.
Keep the named data volumes; use `bash up.sh` / `bash up.sh --upgrade` instead.

## Prune offline duplicate registrations (on talos)

If GitHub shows multiple offline `talos-1`…`talos-4` entries:

```bash
cd ~/lattice-runner
set -a && source .env && set +a
python3 scripts/prune_offline_runners.py          # dry-run
python3 scripts/prune_offline_runners.py --apply  # DELETE safe offline dupes
bash up.sh
```

Uses `GITHUB_RUNNER_TOKEN` as a **PAT** (not a one-hour registration token) via
stdlib Python (`gh` optional). Safe rules: delete offline dupes when an online
peer exists; if all offline for a name, keep the newest id. Does not touch
runners other than `talos-1`…`talos-4`, `talos-light` and `hermes-1`…`hermes-4`.

## Runners

| Service  | RUNNER_NAME | Labels           | Data volume    |
|----------|-------------|------------------|----------------|
| runner-1 | talos-1     | talos, talos-1   | runner-1-data  |
| runner-2 | talos-2     | talos, talos-2   | runner-2-data  |
| runner-3 | talos-3     | talos, talos-3   | runner-3-data  |
| runner-4 | talos-4     | talos, talos-4   | runner-4-data  |
| runner-light | talos-light | talos-light  | runner-light-data |
| hermes-1 (hermes compose) | hermes-1 | hermes, hermes-1 | hermes-1-data |

Each has a **unique stable** `RUNNER_NAME` and its own data volume (required: runners on one host must not share `RUNNER_WORKDIR` — [myoung34 README](https://github.com/myoung34/docker-github-actions-runner/blob/master/README.md)).

## Env (must match upstream)

| Variable | Value | Why |
|----------|--------|-----|
| `CONFIGURED_ACTIONS_RUNNER_FILES_DIR` | `/tmp/runner` | Persist registration ([README](https://github.com/myoung34/docker-github-actions-runner/blob/master/README.md); wiki Reusage) |
| `DISABLE_AUTOMATIC_DEREGISTRATION` | `true` | Required with reusage or entrypoint exits |
| `DISABLE_AUTO_UPDATE` | `true` | Container path; any value is truthy |
| Image | `…:ubuntu-noble` (default; override via `GITHUB_RUNNER_IMAGE_TAG`) | 24.04 matches [setup-python self-hosted Ubuntu](https://github.com/actions/setup-python/blob/main/docs/advanced-usage.md#using-setup-python-with-a-self-hosted-runner); myoung34 rebuilds this tag nightly. **Do not use bare `latest` (resolute)** — pip fails with missing SSL. |

## setup-python / pip SSL

Jobs that use `actions/setup-python` then `pip install` run **inside** these runner containers. setup-python’s docs: Python builds exist only for the same Ubuntu versions as GitHub-hosted runners. myoung34’s `:latest` is **ubuntu resolute**, which is not that set — you get:

`ssl module in Python is not available` / pip cannot fetch PyPI over HTTPS.

**lattice-runner fix:** default image `ubuntu-noble`. After switching, wipe toolcache volumes (they may hold a broken Python from resolute) and upgrade runners (see commands below).

**Workflow side (lattice-log):** `runs-on: [self-hosted, talos]` is fine. A workflow-only workaround is `container: ubuntu:24.04`, but that is a different execution model; prefer fixing the runner OS here.

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

## Switch to ubuntu-noble (pip SSL fix) — must run on talos

Editing this repo on a laptop does nothing until the files are on talos **and** you wipe toolcache + upgrade. Compose mounts named volumes at `/opt/hostedtoolcache` (setup-python’s cache). A job that still says `Packages already satisfied` under `/opt/hostedtoolcache/Python/3.12.10/x64` is using that stale volume.

If `.env` sets `GITHUB_RUNNER_IMAGE_TAG=latest`, change it to `ubuntu-noble` or delete the line.

From the `lattice-runner` project directory on **talos** (Compose project name = directory name → volume prefix `lattice-runner_`):

```bash
# 0) Confirm this checkout defaults to noble
grep 'ubuntu-noble' docker-compose.yml up.sh

# 1) Stop runners
docker compose stop

# 2) Wipe setup-python toolcaches (exact names when project dir is lattice-runner)
docker volume rm \
  lattice-runner_runner-1-toolcache \
  lattice-runner_runner-2-toolcache \
  lattice-runner_runner-3-toolcache \
  lattice-runner_runner-4-toolcache

# If rm says no such volume, list and use the real prefix:
# docker volume ls | grep toolcache

# 3) Pull noble + graceful restart
SESSION_WAIT=90 bash up.sh --upgrade

# 4) MUST pass before re-running CI
docker compose ps
docker compose exec runner-1 bash -lc 'echo IMAGE=$(cat /etc/os-release | grep PRETTY); grep VERSION_ID= /etc/os-release; ls /opt/hostedtoolcache 2>/dev/null || echo toolcache-empty-ok'
docker inspect --format '{{.Config.Image}} {{.Image}}' "$(docker compose ps -q runner-1)"
# Expect: Image myoung34/github-runner:ubuntu-noble, VERSION_ID="24.04", toolcache empty or no Python/

# 5) Only then re-run the lattice-log workflow.
# setup-python should DOWNLOAD Python again (not "already satisfied").
# Optional check after that job (or after manually invoking setup-python):
# docker compose exec runner-1 bash -lc '/opt/hostedtoolcache/Python/3.12.*/x64/bin/python -c "import ssl; print(ssl.OPENSSL_VERSION)"'
```
