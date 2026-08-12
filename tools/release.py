#!/usr/bin/env python3
"""Small, dependency-free release fetch and validation seam."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

PRODUCER_REPO = "boffinate/vcache-packaging"
API_ROOT = "https://api.github.com"
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*-[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA_RE = re.compile(r"^([0-9a-f]{64})  ([^/\r\n]+)$")
REV_RE = re.compile(r"^[1-9][0-9]*$")
HANDOFF_FILES = {".source-tag", ".validated"}


class ValidationError(Exception):
    pass


def routes(path: Path) -> dict[str, dict[str, str]]:
    out = {}
    for no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or fields[0] in out:
            raise ValidationError(f"invalid routes.tsv line {no}")
        target, fmt, arch, image, platform = fields
        if fmt not in ("deb", "rpm") or platform not in ("linux/amd64", "linux/arm64"):
            raise ValidationError(f"invalid route {target}")
        out[target] = {"format": fmt, "arch": arch, "image": image, "platform": platform}
    if not out:
        raise ValidationError("routes.tsv is empty")
    return out


def route_for_tag(tag: str, table: dict[str, dict[str, str]]) -> tuple[str, str, dict[str, str]]:
    if not TAG_RE.fullmatch(tag):
        raise ValidationError("source tag contains unsafe characters")
    matches = [(target, tag[: -(len(target) + 1)]) for target in table if tag.endswith("-" + target)]
    if len(matches) != 1 or not matches[0][1]:
        raise ValidationError("source tag does not end in exactly one allowed target")
    target, engine = matches[0]
    family = engine.split("-", 1)[0]
    if family not in ("vinyl", "varnish"):
        raise ValidationError(f"unsupported engine family {family!r}")
    if not engine[len(family) + 1:]:
        raise ValidationError("source tag has no engine version")
    return family, target, table[target]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checksum_map(stage: Path) -> dict[str, str]:
    sums = stage / "SHA256SUMS"
    if not sums.is_file():
        raise ValidationError("SHA256SUMS is missing")
    result = {}
    for line in sums.read_text().splitlines():
        match = SHA_RE.fullmatch(line)
        if not match or match.group(2) in result:
            raise ValidationError("invalid SHA256SUMS line")
        result[match.group(2)] = match.group(1)
    packages = sorted(p.name for p in stage.iterdir() if p.suffix in (".deb", ".rpm"))
    if not packages or set(result) != set(packages):
        raise ValidationError("checksum filename set does not equal package assets")
    extras = [
        p.name for p in stage.iterdir()
        if p.is_file() and p.name != "SHA256SUMS" and p.suffix not in (".deb", ".rpm")
        and p.name not in HANDOFF_FILES
    ]
    if extras:
        raise ValidationError(f"unexpected release assets: {', '.join(sorted(extras))}")
    if any(sha256(stage / name) != digest for name, digest in result.items()):
        raise ValidationError("package checksum mismatch")
    return result


def validate_asset_names(names: list[str]) -> None:
    if len(names) != len(set(names)):
        raise ValidationError("release contains duplicate asset names")
    for name in names:
        if "/" in name or name in (".", "..") or name in HANDOFF_FILES:
            raise ValidationError(f"unsafe or reserved release asset name: {name}")
        if name != "SHA256SUMS" and Path(name).suffix not in (".deb", ".rpm"):
            raise ValidationError(f"unexpected release asset: {name}")


def _run(args: list[str]) -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "output", "")
        raise ValidationError(f"native metadata command failed: {' '.join(args)} {detail}") from exc


def package_metadata(path: Path, fmt: str) -> dict[str, str]:
    if fmt == "deb":
        values = [_run(["dpkg-deb", "-f", str(path), field])
                  for field in ("Package", "Version", "Architecture")]
        if any(not value or "\n" in value for value in values):
            raise ValidationError(f"invalid Debian metadata in {path.name}")
        return {"name": values[0], "version": values[1], "arch": values[2], "release": ""}
    line = _run(["rpm", "-qp", "--qf", "%{NAME}\n%{VERSION}\n%{RELEASE}\n%{ARCH}\n", str(path)])
    values = line.splitlines()
    if len(values) != 4:
        raise ValidationError(f"invalid RPM metadata in {path.name}")
    return {"name": values[0], "version": values[1], "release": values[2], "arch": values[3]}


def is_engine_package(name: str, family: str) -> bool:
    prefix = "vinyl-cache" if family == "vinyl" else "varnish"
    return name == prefix or (name.startswith(prefix + "-") and not name.startswith(family + "-vmod-"))


def package_revision(meta: dict[str, str], family: str, engine_version: str, fmt: str) -> str:
    engine_name = is_engine_package(meta["name"], family)
    if fmt == "deb":
        if engine_name:
            prefix = engine_version + "-"
            if not meta["version"].startswith(prefix):
                raise ValidationError("engine package version does not match source tag")
            revision = meta["version"][len(prefix):]
        else:
            marker = f"~{family}{engine_version}."
            if marker not in meta["version"]:
                raise ValidationError("VMOD Debian version does not match source tag")
            revision = meta["version"].rsplit(".", 1)[-1]
    else:
        marker = f"{family}{engine_version}."
        if engine_name:
            if meta["version"] != engine_version:
                raise ValidationError("engine package version does not match source tag")
            revision = meta["release"].split(".", 1)[0]
        elif marker in meta["release"]:
            revision = meta["release"].split(marker, 1)[1].split(".", 1)[0]
        else:
            raise ValidationError("RPM release does not match source tag")
    if not REV_RE.fullmatch(revision):
        raise ValidationError("package revision must be a positive decimal")
    return revision


def validate_stage(stage: Path, tag: str, route_file: Path) -> None:
    table = routes(route_file)
    family, target, route = route_for_tag(tag, table)
    digests = checksum_map(stage)
    package_paths = sorted(stage / name for name in digests)
    if any(p.suffix != ("." + route["format"]) for p in package_paths):
        raise ValidationError("release mixes package formats or disagrees with route")
    engine_version = tag[: -(len(target) + 1)].split("-", 1)[1]
    revisions = set()
    for path in package_paths:
        meta = package_metadata(path, route["format"])
        if meta["arch"] != route["arch"]:
            raise ValidationError(f"{path.name}: architecture {meta['arch']} disagrees with route")
        if not (is_engine_package(meta["name"], family) or meta["name"].startswith(f"{family}-vmod-")):
            raise ValidationError(f"{path.name}: package family mismatch")
        revisions.add(package_revision(meta, family, engine_version, route["format"]))
    if len(revisions) != 1:
        raise ValidationError("package set has multiple revisions")


@contextmanager
def github_open(url: str, accept: str):
    headers = {"Accept": accept, "User-Agent": "vcache-repository"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
            yield response
    except OSError as exc:
        raise ValidationError(f"GitHub request failed: {url}") from exc


def api_json(path: str) -> dict:
    with github_open(API_ROOT + path, "application/vnd.github+json") as response:
        return json.load(response)


def fetch_asset(url: str, destination: Path) -> None:
    with github_open(url, "application/octet-stream") as response, destination.open("wb") as output:
        while block := response.read(1024 * 1024):
            output.write(block)


def fetch(tag: str, stage: Path, route_file: Path) -> None:
    table = routes(route_file)
    route_for_tag(tag, table)
    release = api_json(f"/repos/{PRODUCER_REPO}/releases/tags/{urllib.parse.quote(tag, safe='')}")
    if release.get("draft") or release.get("prerelease"):
        raise ValidationError("release must be non-draft and non-prerelease")
    assets = release.get("assets", [])
    names = [asset.get("name", "") for asset in assets]
    validate_asset_names(names)
    stage.mkdir(parents=True, exist_ok=True)
    for asset in assets:
        name = asset["name"]
        fetch_asset(asset["url"], stage / name)
    (stage / ".source-tag").write_text(tag + "\n")
    validate_stage(stage, tag, route_file)
    (stage / ".validated").write_text("ok\n")


def verify_command(stage: Path, route_file: Path) -> None:
    marker = stage / ".source-tag"
    if not marker.is_file() or not (stage / ".validated").is_file():
        raise ValidationError("stage is missing validated handoff markers")
    validate_stage(stage, marker.read_text().strip(), route_file)


def describe(stage: Path, route_file: Path) -> None:
    tag = (stage / ".source-tag").read_text().strip()
    family, target, route = route_for_tag(tag, routes(route_file))
    print("\t".join((family, target, route["format"], route["arch"], route["image"], route["platform"])))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("fetch", "verify", "describe"))
    parser.add_argument("--tag")
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--routes", type=Path, default=Path(__file__).parents[1] / "routes.tsv")
    args = parser.parse_args(argv)
    try:
        if args.command == "fetch":
            if not args.tag:
                parser.error("fetch requires --tag")
            fetch(args.tag, args.stage, args.routes)
        elif args.command == "verify":
            verify_command(args.stage, args.routes)
        else:
            describe(args.stage, args.routes)
    except ValidationError as exc:
        print(f"validation failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
