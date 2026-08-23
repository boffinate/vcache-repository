#!/usr/bin/env python3
"""Purge replaced repository URLs from the Cloudflare edge cache."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_ROOT = "https://api.cloudflare.com/client/v4"
BATCH_LIMIT = 100
ATTEMPTS = 3
# Metadata a client reads as one signed set. Splitting such a group across two
# purge requests would leave a window where a new index is served against the
# stale files it names.
GROUP_MARKERS = ("/dists/", "/repodata/")


class PurgeError(Exception):
    pass


def group_of(url: str) -> str | None:
    for marker in GROUP_MARKERS:
        index = url.find(marker)
        if index >= 0:
            return url[: index + len(marker)]
    return None


def batches(urls: list[str]) -> list[list[str]]:
    ordered = sorted(set(urls))
    out = [ordered[start:start + BATCH_LIMIT] for start in range(0, len(ordered), BATCH_LIMIT)]
    for current, following in zip(out, out[1:]):
        boundary = group_of(current[-1])
        if boundary is not None and boundary == group_of(following[0]):
            raise PurgeError(f"purge batch boundary splits {boundary}")
    return out


def read_urls(path: Path) -> list[str]:
    urls = [line.strip() for line in path.read_text().splitlines()]
    urls = [url for url in urls if url]
    for url in urls:
        if not url.startswith("https://"):
            raise PurgeError(f"refusing to purge a non-HTTPS URL: {url}")
    return urls


def require_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise PurgeError(f"missing environment variable: {name}")
    return value


def post(files: list[str]) -> None:
    zone = require_env("CLOUDFLARE_ZONE_ID")
    token = require_env("CLOUDFLARE_API_TOKEN")
    root = os.environ.get("CLOUDFLARE_API_BASE", API_ROOT).rstrip("/")
    # Only ever purge the exact URLs this publication replaced; a zone-wide
    # purge would evict every other site on the account's zone.
    request = urllib.request.Request(
        f"{root}/zones/{zone}/purge_cache",
        data=json.dumps({"files": files}).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    for attempt in range(1, ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code == 429 and attempt < ATTEMPTS:
                time.sleep(2 ** attempt)
                continue
            raise PurgeError(f"cache purge failed with HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise PurgeError(f"cache purge could not reach the API: {exc.reason}") from exc
        if not payload.get("success"):
            raise PurgeError(f"cache purge was rejected: {json.dumps(payload.get('errors', []))}")
        return


def dry_run(batch: list[str]) -> None:
    if os.environ.get("PURGE_DRY_RUN_FAIL") == "1":
        raise PurgeError("cache purge failed (forced dry-run failure)")
    log = os.environ.get("PURGE_DRY_RUN_LOG")
    if not log:
        return
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"files": batch}, sort_keys=True) + "\n")


def purge(path: Path) -> None:
    live = os.environ.get("PURGE_DRY_RUN") != "1"
    for batch in batches(read_urls(path)):
        if live:
            post(batch)
        else:
            dry_run(batch)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--urls-file", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        purge(args.urls_file)
    except PurgeError as exc:
        print(f"purge failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
