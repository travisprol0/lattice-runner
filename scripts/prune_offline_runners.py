#!/usr/bin/env python3
"""Prune duplicate offline talos-* GitHub Actions runner registrations.

Recreating Compose runners without deregistration (or wiping runner-*-data)
leaves multiple offline registrations with the same RUNNER_NAME. This script
lists repo runners via the GitHub API and deletes safe offline duplicates.

Requires GITHUB_RUNNER_TOKEN as a **PAT** (classic `repo` or fine-grained with
Actions admin on the repo). A short-lived GitHub UI “registration token” can
register runners but cannot list/delete them. Uses urllib only — `gh` may be
missing on talos.

Safe rules (per name talos-1 … talos-4):
  - If any registration is online: delete all offline duplicates for that name.
  - If all are offline and more than one exists: keep the newest id, delete older.
  - Never deletes non-talos-* runners.
  - Dry-run by default; pass --apply to DELETE.

Never use `docker compose down -v` as a routine fix — that wipes registration
volumes and creates this problem again.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = os.environ.get("GITHUB_RUNNER_REPO", "travisprol0/lattice-log")
API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
NAME_RE = re.compile(r"^talos-[1-4]$")


def _request(method: str, url: str, token: str) -> dict | list | None:
    req = urllib.request.Request(
        url,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "lattice-runner-prune-offline",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            if not body:
                return None
            return json.loads(body.decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise SystemExit(f"HTTP {exc.code} {method} {url}: {detail}") from exc


def _list_runners(token: str) -> list[dict]:
    runners: list[dict] = []
    url: str | None = f"{API}/repos/{REPO}/actions/runners?per_page=100"
    while url:
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "lattice-runner-prune-offline",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
            runners.extend(payload.get("runners", []))
            link = resp.headers.get("Link", "")
        url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                match = re.search(r"<([^>]+)>", part)
                if match:
                    url = match.group(1)
    return runners


def _plan_deletes(runners: list[dict]) -> list[dict]:
    by_name: dict[str, list[dict]] = {}
    for runner in runners:
        name = str(runner.get("name") or "")
        if not NAME_RE.match(name):
            continue
        by_name.setdefault(name, []).append(runner)

    to_delete: list[dict] = []
    for name, group in sorted(by_name.items()):
        online = [r for r in group if r.get("status") == "online"]
        offline = [r for r in group if r.get("status") != "online"]
        if online:
            to_delete.extend(offline)
            continue
        if len(offline) <= 1:
            continue
        # Keep newest id (highest) when everything is offline.
        offline_sorted = sorted(offline, key=lambda r: int(r["id"]), reverse=True)
        to_delete.extend(offline_sorted[1:])
    return to_delete


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually DELETE runners (default is dry-run)",
    )
    args = parser.parse_args()

    token = os.environ.get("GITHUB_RUNNER_TOKEN", "").strip()
    if not token:
        print("ERROR: set GITHUB_RUNNER_TOKEN", file=sys.stderr)
        return 1

    print(f"Listing runners for {REPO} …")
    runners = _list_runners(token)
    talos = [r for r in runners if NAME_RE.match(str(r.get("name") or ""))]
    print(f"Found {len(talos)} talos-1…4 registration(s) (of {len(runners)} total):")
    for r in sorted(talos, key=lambda x: (str(x.get("name")), int(x["id"]))):
        print(
            f"  id={r['id']} name={r.get('name')} "
            f"status={r.get('status')} busy={r.get('busy')}"
        )

    to_delete = _plan_deletes(runners)
    if not to_delete:
        print("Nothing to prune.")
        return 0

    print(f"Would delete {len(to_delete)} offline duplicate(s):")
    for r in to_delete:
        print(f"  id={r['id']} name={r.get('name')} status={r.get('status')}")

    if not args.apply:
        print("Dry-run only. Re-run with --apply to delete.")
        return 0

    for r in to_delete:
        rid = int(r["id"])
        print(f"Deleting runner id={rid} name={r.get('name')} …")
        _request("DELETE", f"{API}/repos/{REPO}/actions/runners/{rid}", token)
        print(f"  deleted {rid}")

    print("Done. Prefer bash up.sh next — do not compose down -v.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
