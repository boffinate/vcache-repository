#!/usr/bin/env python3
"""Static browsable pages for the published repository roots."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import string
import sys
import urllib.parse
from pathlib import Path

import release

PREFIX = "vinyl-cache/"
RESERVED = "index.html"
# Documentation lives in Git, not in the bucket, so relative README links have
# to point somewhere a reader of the published page can actually follow.
GITHUB_BLOB = "https://github.com/boffinate/vcache-repository/blob/main/"
MARKERS = {"deb": ("apt", "dists/stable/InRelease"), "rpm": ("rpm", "repodata/repomd.xml")}
BINARY_PACKAGES_RE = re.compile(r"^apt/([^/]+)/([^/]+)/dists/stable/main/binary-[^/]+/Packages$")
FINGERPRINT_RE = re.compile(r"\b[0-9A-F]{40}\b")
MD5_RE = re.compile(r"^[0-9a-f]{32}$")

HEADING_RE = re.compile(r"^(#{1,2}) (\S.*)$")
FENCE_RE = re.compile(r"^~~~([A-Za-z0-9]*)$")
ITEM_RE = re.compile(r"^- (\S.*)$")
INLINE_RE = re.compile(r"`[^`]+`|\*\*[^*]+\*\*|\[[^\[\]]+\]\([^()\s]+\)")
# Anything Markdown would have treated as structure but this renderer does not
# implement: failing loudly keeps the README from silently rendering wrong.
UNSUPPORTED_INLINE = set("`*[]<>|")
UNSUPPORTED_BLOCK_RE = re.compile(r"^(#|-|\*|\+|>|\||=|\d+\.|```|    |\t)")


class SiteError(Exception):
    pass


def quote_path(path: str, directory: bool = False) -> str:
    quoted = "/".join(urllib.parse.quote(part, safe="") for part in path.split("/"))
    return quoted + "/" if directory else quoted


def attribute(value: str) -> str:
    return html.escape(value, quote=True)


def human_size(size: int) -> str:
    if size < 1024:
        return f"{size} B"
    value = float(size)
    for unit in ("KiB", "MiB", "GiB"):
        value /= 1024
        if value < 1024:
            return f"{value:.1f} {unit}"
    return f"{value:.1f} GiB"


def escape_plain(text: str) -> None | str:
    unsupported = UNSUPPORTED_INLINE.intersection(text)
    if unsupported:
        raise SiteError(f"unsupported Markdown syntax near {''.join(sorted(unsupported))!r}")
    return html.escape(text)


def link_target(url: str) -> str:
    if url.startswith(("https://", "http://", "mailto:", "#")):
        return url
    if url.startswith("/") or ".." in url.split("/"):
        raise SiteError(f"unsupported link target: {url}")
    return GITHUB_BLOB + url


def render_inline(text: str) -> str:
    if "![" in text:
        raise SiteError("images cannot be published: the site has no assets of its own")
    out, position = [], 0
    for match in INLINE_RE.finditer(text):
        out.append(escape_plain(text[position:match.start()]))
        token = match.group(0)
        if token.startswith("`"):
            out.append("<code>" + html.escape(token[1:-1]) + "</code>")
        elif token.startswith("**"):
            out.append("<strong>" + escape_plain(token[2:-2]) + "</strong>")
        else:
            label, _, target = token[1:-1].partition("](")
            out.append(f'<a href="{attribute(link_target(target))}">{escape_plain(label)}</a>')
        position = match.end()
    out.append(escape_plain(text[position:]))
    return "".join(out)


def render_markdown(text: str) -> str:
    """Render exactly the Markdown subset the README uses, rejecting the rest."""
    lines = text.splitlines()
    out, index = [], 0
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        if FENCE_RE.match(line):
            index += 1
            block = []
            while index < len(lines) and lines[index] != "~~~":
                if FENCE_RE.match(lines[index]):
                    raise SiteError("nested fenced block")
                block.append(lines[index])
                index += 1
            if index == len(lines):
                raise SiteError("unterminated fenced block")
            index += 1
            out.append("<pre><code>" + html.escape("\n".join(block)) + "</code></pre>")
            continue
        heading = HEADING_RE.match(line)
        if heading:
            level = len(heading.group(1))
            out.append(f"<h{level}>{render_inline(heading.group(2))}</h{level}>")
            index += 1
            continue
        if ITEM_RE.match(line):
            items = []
            while index < len(lines):
                item = ITEM_RE.match(lines[index])
                if not item:
                    break
                items.append(f"<li>{render_inline(item.group(1))}</li>")
                index += 1
            out.append("<ul>" + "".join(items) + "</ul>")
            continue
        paragraph = []
        while index < len(lines) and lines[index].strip():
            if paragraph and (FENCE_RE.match(lines[index]) or HEADING_RE.match(lines[index])
                              or ITEM_RE.match(lines[index])):
                break
            if UNSUPPORTED_BLOCK_RE.match(lines[index]):
                raise SiteError(f"unsupported Markdown block: {lines[index]!r}")
            paragraph.append(lines[index].strip())
            index += 1
        out.append("<p>" + render_inline(" ".join(paragraph)) + "</p>")
    return "\n".join(out)


def readme_title(text: str) -> str:
    for line in text.splitlines():
        heading = HEADING_RE.match(line)
        if heading and len(heading.group(1)) == 1:
            return heading.group(2)
    raise SiteError("the README has no top-level heading")


def check_fingerprint(readme: str, fingerprint: str) -> None:
    """The root page advertises the archive key, so it must name the signing key in use."""
    found = set(FINGERPRINT_RE.findall(readme))
    if not found:
        raise SiteError("the README advertises no archive-key fingerprint")
    if found != {fingerprint.upper()}:
        raise SiteError("the README fingerprint disagrees with the configured archive key")


def parse_listing(document: dict) -> tuple[list[dict], dict[str, str]]:
    entries: list[dict] = []
    pages: dict[str, str] = {}
    for item in document.get("Contents") or []:
        key = item["Key"]
        if not key.startswith(PREFIX) or key.endswith("/"):
            continue
        path = key[len(PREFIX):]
        if path == RESERVED or path.endswith("/" + RESERVED):
            pages[path] = (item.get("ETag") or "").strip('"')
            continue
        entries.append({
            "path": path,
            "size": int(item.get("Size") or 0),
            "modified": str(item.get("LastModified") or ""),
        })
    entries.sort(key=lambda entry: entry["path"])
    return entries, pages


def build_tree(entries: list[dict]) -> dict[str, dict]:
    tree: dict[str, dict] = {"": {"dirs": set(), "files": []}}
    for entry in entries:
        parts = entry["path"].split("/")
        directory = ""
        for part in parts[:-1]:
            child = f"{directory}{part}/"
            tree.setdefault(child, {"dirs": set(), "files": []})
            tree[directory]["dirs"].add(child)
            directory = child
        tree[directory]["files"].append(entry)
    return tree


def parse_packages(text: str) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    current: dict[str, str] = {}
    field = ""
    for line in text.splitlines():
        if not line.strip():
            if current:
                stanzas.append(current)
                current, field = {}, ""
            continue
        if line[0] in " \t":
            if not field:
                raise SiteError("Packages continuation line without a field")
            current[field] += "\n" + line.strip()
            continue
        name, separator, value = line.partition(":")
        if not separator:
            raise SiteError(f"malformed Packages line: {line!r}")
        field = name.strip()
        current[field] = value.strip()
    if current:
        stanzas.append(current)
    return stanzas


def parse_rpm_filename(name: str) -> dict[str, str]:
    """RPM filenames carry no Epoch, so the result is an NVRA and never a NEVRA."""
    if not name.endswith(".rpm"):
        raise SiteError(f"not an RPM filename: {name!r}")
    stem, _, arch = name[:-len(".rpm")].rpartition(".")
    stem, _, revision = stem.rpartition("-")
    package, _, version = stem.rpartition("-")
    if not (package and version and revision and arch):
        raise SiteError(f"malformed RPM filename: {name!r}")
    return {"name": package, "version": version, "release": revision, "arch": arch}


def target_status(routes_table: dict[str, dict[str, str]], keys: set[str]) -> list[dict]:
    families: dict[tuple[str, str], str] = {}
    for key in keys:
        for fmt, (root, marker) in MARKERS.items():
            suffix = "/" + marker
            if key.startswith(root + "/") and key.endswith(suffix):
                family, separator, target = key[len(root) + 1:-len(suffix)].partition("/")
                if separator and family and "/" not in target:
                    families[(fmt, target)] = family
    rows = []
    for target, route in routes_table.items():
        fmt = route["format"]
        family = families.get((fmt, target))
        rows.append({
            "target": target,
            "format": fmt,
            "arch": route["arch"],
            "path": f"{MARKERS[fmt][0]}/{family}/{target}/" if family else "",
        })
    return rows


def packages_keys(entries: list[dict]) -> list[str]:
    return [PREFIX + entry["path"] for entry in entries if BINARY_PACKAGES_RE.match(entry["path"])]


def table(headers: list[str], rows: list[list[str]]) -> str:
    head = "".join(f"<th>{html.escape(header)}</th>" for header in headers)
    body = "".join("<tr>" + "".join(row) + "</tr>" for row in rows)
    return f'<div class="scroll"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>'


def target_table(rows: list[dict]) -> str:
    lines = []
    for row in rows:
        if row["path"]:
            link = f'<a href="{attribute(quote_path(row["path"].rstrip("/"), directory=True))}">browse</a>'
        else:
            link = '<span class="pending">not yet published</span>'
        lines.append([
            f'<td class="name path">{html.escape(row["target"])}</td>',
            f'<td>{html.escape(row["format"])}</td>',
            f'<td>{html.escape(row["arch"])}</td>',
            f"<td>{link}</td>",
        ])
    return "<h2>Targets</h2>\n" + table(["Target", "Format", "Architecture", "Repository"], lines)


def deb_table(stanzas: list[dict[str, str]]) -> str:
    rows = []
    for stanza in sorted(stanzas, key=lambda item: (item.get("Package", ""), item.get("Version", ""))):
        filename = stanza.get("Filename", "")
        name = html.escape(stanza.get("Package", ""))
        cell = f'<a href="{attribute(quote_path(filename))}">{name}</a>' if filename else name
        rows.append([
            f'<td class="name path">{cell}</td>',
            f'<td class="path">{html.escape(stanza.get("Version", ""))}</td>',
            f'<td>{html.escape(stanza.get("Architecture", ""))}</td>',
            f'<td class="size">{human_size(int(stanza.get("Size") or 0))}</td>',
        ])
    return "<h2>Current packages</h2>\n" + table(["Package", "Version", "Architecture", "Size"], rows)


def rpm_table(files: list[dict]) -> str:
    rows = []
    for entry in files:
        nvra = parse_rpm_filename(entry["name"])
        link = f'<a href="{attribute(quote_path("Packages/" + entry["name"]))}">{html.escape(nvra["name"])}</a>'
        rows.append([
            f'<td class="name path">{link}</td>',
            f'<td class="path">{html.escape(nvra["version"])}</td>',
            f'<td class="path">{html.escape(nvra["release"])}</td>',
            f'<td>{html.escape(nvra["arch"])}</td>',
            f'<td class="size">{human_size(entry["size"])}</td>',
        ])
    return "<h2>Current packages (NVRA)</h2>\n" + table(
        ["Name", "Version", "Release", "Architecture", "Size"], rows)


def listing_body(directory: str, node: dict, extra: str) -> str:
    rows = []
    for child in sorted(node["dirs"]):
        name = child[len(directory):]
        rows.append([
            f'<td class="name path"><a href="{attribute(quote_path(name))}">{html.escape(name)}</a></td>',
            '<td class="size">-</td>',
            '<td class="time"></td>',
        ])
    for entry in sorted(node["files"], key=lambda item: item["path"]):
        name = entry["path"][len(directory):]
        rows.append([
            f'<td class="name path"><a href="{attribute(quote_path(name))}">{html.escape(name)}</a></td>',
            f'<td class="size">{human_size(entry["size"])}</td>',
            f'<td class="time">{html.escape(entry["modified"])}</td>',
        ])
    parts = [f'<h1>Index of <span class="path">/{html.escape(PREFIX + directory)}</span></h1>',
             '<p class="up"><a href="../">Parent directory</a></p>']
    if extra:
        parts.append(extra)
    parts.append("<h2>Contents</h2>")
    parts.append(table(["Name", "Size", "Last modified"], rows))
    return "\n".join(parts)


def render(template: str, title: str, body: str) -> str:
    return string.Template(template).substitute(title=html.escape(title), body=body)


def build_pages(listing: dict, routes_table: dict[str, dict[str, str]], readme: str,
                template: str, packages: dict[str, str], fingerprint: str) -> dict[str, str]:
    check_fingerprint(readme, fingerprint)
    entries, _ = parse_listing(listing)
    tree = build_tree(entries)
    rows = target_status(routes_table, {entry["path"] for entry in entries})

    extras: dict[str, str] = {}
    for key, text in packages.items():
        match = BINARY_PACKAGES_RE.match(key[len(PREFIX):])
        if not match:
            raise SiteError(f"not a binary Packages object: {key}")
        extras[f"apt/{match.group(1)}/{match.group(2)}/"] = deb_table(parse_packages(text))
    for row in rows:
        if row["format"] != "rpm" or not row["path"]:
            continue
        node = tree.get(row["path"] + "Packages/")
        if node:
            extras[row["path"]] = rpm_table(
                [{"name": entry["path"].split("/")[-1], "size": entry["size"]} for entry in node["files"]])

    pages = {PREFIX + RESERVED: render(template, readme_title(readme),
                                       render_markdown(readme) + "\n" + target_table(rows))}
    for directory, node in sorted(tree.items()):
        if not directory:
            continue
        pages[PREFIX + directory + RESERVED] = render(
            template, f"Index of /{PREFIX}{directory}", listing_body(directory, node, extras.get(directory, "")))
    return pages


def plan(listing: dict, site: Path) -> list[str]:
    _, existing = parse_listing(listing)
    lines = []
    for path in sorted(site.rglob("*")):
        if not path.is_file():
            continue
        key = path.relative_to(site).as_posix()
        # R2 reports the MD5 of single-part uploads as the ETag; anything else
        # (a multipart-style ETag, or no entry at all) cannot be compared.
        digest = hashlib.md5(path.read_bytes(), usedforsecurity=False).hexdigest()
        etag = existing.get(key[len(PREFIX):], "")
        action = "skip" if MD5_RE.match(etag) and etag == digest else "upload"
        lines.append(f"{action}\t{key}")
    return lines


def load_listing(path: Path) -> dict:
    return json.loads(path.read_text() or "{}")


def command_build(args: argparse.Namespace) -> None:
    listing = load_listing(args.listing)
    entries, _ = parse_listing(listing)
    packages = {}
    for key in packages_keys(entries):
        source = args.packages_dir / key
        if not source.is_file():
            raise SiteError(f"missing downloaded Packages file: {key}")
        packages[key] = source.read_text()
    pages = build_pages(listing, release.routes(args.routes), args.readme.read_text(),
                        args.template.read_text(), packages, args.fingerprint)
    for key, page in pages.items():
        destination = args.out / key
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(page)


def command_plan(args: argparse.Namespace) -> None:
    for line in plan(load_listing(args.listing), args.site):
        print(line)


def command_packages(args: argparse.Namespace) -> None:
    entries, _ = parse_listing(load_listing(args.listing))
    for key in packages_keys(entries):
        print(key)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--listing", type=Path, required=True)
    build.add_argument("--routes", type=Path, default=Path(__file__).parents[1] / "routes.tsv")
    build.add_argument("--readme", type=Path, default=Path(__file__).parents[1] / "README.md")
    build.add_argument("--template", type=Path, default=Path(__file__).parents[1] / "site/page.html.tmpl")
    build.add_argument("--packages-dir", type=Path, required=True)
    build.add_argument("--fingerprint", required=True)
    build.add_argument("--out", type=Path, required=True)
    build.set_defaults(handler=command_build)
    planner = sub.add_parser("plan")
    planner.add_argument("--listing", type=Path, required=True)
    planner.add_argument("--site", type=Path, required=True)
    planner.set_defaults(handler=command_plan)
    lister = sub.add_parser("packages")
    lister.add_argument("--listing", type=Path, required=True)
    lister.set_defaults(handler=command_packages)
    args = parser.parse_args(argv)
    try:
        args.handler(args)
    except (SiteError, release.ValidationError) as exc:
        print(f"site generation failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
