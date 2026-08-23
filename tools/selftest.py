#!/usr/bin/env python3
"""Host-safe tests for the release and route public seams."""
import base64
import hashlib
import importlib.util
import re
import tempfile
from pathlib import Path

import purge
import release

# tools/site.py cannot be imported by name: the interpreter has already bound
# the standard library's site module under that name.
_spec = importlib.util.spec_from_file_location("vcache_site", Path(__file__).parent / "site.py")
site = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(site)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def rejects(call, message: str) -> None:
    try:
        call()
    except release.ValidationError:
        return
    raise AssertionError(message)


def raises(call, error, message: str) -> None:
    try:
        call()
    except error:
        return
    raise AssertionError(message)


def armored_key_fingerprint(path: Path) -> str:
    """Fingerprint of an armored OpenPGP v4 primary key, without needing gpg."""
    lines = path.read_text().splitlines()
    start = lines.index("-----BEGIN PGP PUBLIC KEY BLOCK-----") + 1
    while lines[start].strip():
        start += 1
    body = [line for line in lines[start:] if not line.startswith(("=", "-----"))]
    data = base64.b64decode("".join(body))
    if data[0] != 0x99:
        raise AssertionError("unexpected first OpenPGP packet")
    length = int.from_bytes(data[1:3], "big")
    return hashlib.sha1(data[:3 + length]).hexdigest().upper()


def test_routes_and_tag() -> None:
    table = release.routes(Path(__file__).parents[1] / "routes.tsv")
    family, version, target, route = release.route_for_tag("vinyl-42.3.7-debian-13-amd64", table)
    expect((family, version, target, route["format"], route["arch"]) ==
           ("vinyl", "42.3.7", "debian-13-amd64", "deb", "amd64"), "route resolution")
    for bad in ("vinyl-42.3.7-nope", "../x-debian-13-amd64", "varnish-el10-x86_64"):
        rejects(lambda: release.route_for_tag(bad, table), f"unsafe or unknown tag accepted: {bad}")


def test_strict_checksums() -> None:
    with tempfile.TemporaryDirectory() as directory:
        stage = Path(directory)
        payload = stage / "vinyl-cache_42.3.7-1_amd64.deb"
        payload.write_bytes(b"known package bytes")
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        (stage / "SHA256SUMS").write_text(f"{digest}  {payload.name}\n")
        expect(release.checksum_map(stage)[payload.name] == digest, "checksum map")
        (stage / "SHA256SUMS").write_text(f"{digest} {payload.name}\n")
        rejects(lambda: release.checksum_map(stage), "single-space checksum accepted")
        (stage / "SHA256SUMS").write_text(f"{digest}  {payload.name}\n")
        (stage / ".unexpected-release-asset").write_text("not a handoff marker\n")
        rejects(lambda: release.checksum_map(stage), "unexpected hidden release asset accepted")


def test_release_asset_names_reserve_handoff_markers() -> None:
    release.validate_asset_names(["vinyl-cache_42.3.7-1_amd64.deb", "SHA256SUMS"])
    for names in (
        ["vinyl-cache_42.3.7-1_amd64.deb", "SHA256SUMS", ".validated"],
        ["vinyl-cache_42.3.7-1_amd64.deb", "SHA256SUMS", "notes.txt"],
    ):
        rejects(lambda: release.validate_asset_names(names), f"invalid release asset set accepted: {names}")


def test_revision_order_inputs() -> None:
    deb_engine = {"name": "vinyl-cache", "version": "42.3.7-2", "arch": "amd64", "release": ""}
    deb_vmod = {"name": "vinyl-vmod-example", "version": "6.5-1~vinyl42.3.7.2", "arch": "amd64", "release": ""}
    rpm_engine = {"name": "vinyl-cache", "version": "42.3.7", "release": "2", "arch": "x86_64"}
    rpm_vmod = {"name": "vinyl-vmod-example", "version": "6.5", "release": "1.vinyl42.3.7.2.el10", "arch": "x86_64"}
    expect(release.package_revision(deb_engine, "vinyl", "42.3.7", "deb") == "2", "Debian engine revision")
    expect(release.package_revision(deb_vmod, "vinyl", "42.3.7", "deb") == "2", "Debian VMOD revision")
    expect(release.package_revision(rpm_engine, "vinyl", "42.3.7", "rpm") == "2", "RPM engine revision")
    expect(release.package_revision(rpm_vmod, "vinyl", "42.3.7", "rpm") == "2", "RPM VMOD revision")
    expect(release.is_engine_package("vinyl-cache-devel", "vinyl"), "Vinyl development package")
    expect(release.is_engine_package("varnish-devel", "varnish"), "Varnish development package")
    expect(not release.is_engine_package("varnish-vmod-example", "varnish"), "Varnish VMOD is not an engine package")
    wrong_rpm_engine = rpm_engine | {"version": "42.3.8"}
    rejects(lambda: release.package_revision(wrong_rpm_engine, "vinyl", "42.3.7", "rpm"),
            "RPM engine version may disagree with the source tag")


def test_markdown_subset() -> None:
    root = Path(__file__).parents[1]
    readme = (root / "README.md").read_text()
    fingerprints = set(re.findall(r"\b[0-9A-F]{40}\b", readme))
    expect(fingerprints == {armored_key_fingerprint(root / "keys/vcache-archive-keyring.asc")},
           "the README advertises exactly the checked-in archive-key fingerprint")
    expect("packages.boffinate.com/vinyl-cache/" in readme,
           "the README points readers at the browsable repository")
    body = site.render_markdown(readme)
    expect("<h1>Vinyl Cache package repository</h1>" in body, "the README renders its top-level heading")
    expect("<ul><li>" in body and "<pre><code>" in body, "the README renders lists and fenced blocks")
    expect('href="https://github.com/boffinate/vcache-repository/blob/main/docs/' in body,
           "relative README links are rewritten to the source repository")
    for unsupported in ("### too deep\n", "> quoted\n", "1. numbered\n", "| a | b |\n",
                        "```\ncode\n```\n", "text with *emphasis*\n", "~~~\nunterminated\n",
                        "an ![image](x.png)\n"):
        raises(lambda: site.render_markdown(unsupported), site.SiteError,
               f"unsupported Markdown accepted: {unsupported!r}")


def synthetic_listing() -> dict:
    keys = [
        ("vinyl-cache/vcache-archive-keyring.asc", 1347),
        ("vinyl-cache/index.html", 4096),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/index.html", 4096),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/vcache-vinyl.sources", 180),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/dists/stable/InRelease", 2048),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/dists/stable/main/binary-amd64/Packages", 700),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/pool/main/v/vinyl-cache/vinyl-cache_42.3.7-1_amd64.deb", 900),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/pool/main/v/vinyl-cache/vinyl-cache_42.3.7-2_amd64.deb", 950),
        ("vinyl-cache/apt/vinyl/debian-13-amd64/pool/main/v/vinyl-cache/od d <name>#?%é.deb", 12),
        ("vinyl-cache/rpm/vinyl/el10-x86_64/repodata/repomd.xml", 500),
        ("vinyl-cache/rpm/vinyl/el10-x86_64/Packages/vinyl-cache-42.3.7-1.x86_64.rpm", 4200),
    ]
    return {"Contents": [{"Key": key, "Size": size, "LastModified": "2026-08-23T09:00:00+00:00",
                          "ETag": '"%s"' % ("0" * 32)} for key, size in keys]}


def test_site_generator() -> None:
    root = Path(__file__).parents[1]
    packages_key = "vinyl-cache/apt/vinyl/debian-13-amd64/dists/stable/main/binary-amd64/Packages"
    stanza = ("Package: vinyl-cache\nVersion: 42.3.7-2\nArchitecture: amd64\n"
              "Filename: pool/main/v/vinyl-cache/vinyl-cache_42.3.7-2_amd64.deb\nSize: 950\n\n")
    pages = site.build_pages(synthetic_listing(), release.routes(root / "routes.tsv"),
                             (root / "README.md").read_text(),
                             (root / "site/page.html.tmpl").read_text(), {packages_key: stanza},
                             armored_key_fingerprint(root / "keys/vcache-archive-keyring.asc"))
    for key, page in pages.items():
        expect("index.html</a>" not in page, f"{key} shows the reserved index.html as an entry")
    expect("vinyl-cache/apt/vinyl/ubuntu-26.04-amd64/index.html" not in pages,
           "an unpublished target gets no pages")
    home = pages["vinyl-cache/index.html"]
    expect('<a href="apt/vinyl/debian-13-amd64/">' in home, "the target table links a published target")
    expect("not yet published" in home, "the target table marks a pending target")
    pool = pages["vinyl-cache/apt/vinyl/debian-13-amd64/pool/main/v/vinyl-cache/index.html"]
    expect('href="od%20d%20%3Cname%3E%23%3F%25%C3%A9.deb"' in pool, "file names are quoted per segment")
    expect(">od d &lt;name&gt;#?%é.deb<" in pool, "file names are escaped for display")
    expect("vinyl-cache_42.3.7-1_amd64.deb" in pool, "historical pool files stay listed")
    target = pages["vinyl-cache/apt/vinyl/debian-13-amd64/index.html"]
    expect('href="dists/"' in target and 'href="vcache-vinyl.sources"' in target,
           "directory links end in a slash and file links do not")
    expect("42.3.7-2" in target and "42.3.7-1" not in target,
           "the package table shows only the current version")
    rpm = pages["vinyl-cache/rpm/vinyl/el10-x86_64/index.html"]
    expect("NVRA" in rpm and 'href="Packages/vinyl-cache-42.3.7-1.x86_64.rpm"' in rpm,
           "the RPM table is labelled NVRA and links its packages")
    expect(site.parse_rpm_filename("vinyl-cache-42.3.7-1.x86_64.rpm") ==
           {"name": "vinyl-cache", "version": "42.3.7", "release": "1", "arch": "x86_64"},
           "RPM filenames parse as NVRA")
    listing = {"Contents": [{"Key": "vinyl-cache/index.html", "Size": 1, "LastModified": "",
                             "ETag": '"d41d8cd98f00b204e9800998ecf8427e-3"'}]}
    with tempfile.TemporaryDirectory() as directory:
        page = Path(directory) / "vinyl-cache/index.html"
        page.parent.mkdir(parents=True)
        page.write_bytes(b"")
        expect(site.plan(listing, Path(directory)) == ["upload\tvinyl-cache/index.html"],
               "a composite ETag cannot be compared and must be re-uploaded")


def test_purge_batching() -> None:
    urls = [f"https://packages.test.invalid/vinyl-cache/pool/p{number:04d}.deb" for number in range(250)]
    groups = purge.batches(urls + urls[:40])
    expect([len(group) for group in groups] == [100, 100, 50],
           "250 distinct URLs are deduplicated into three batches")
    metadata = [f"https://packages.test.invalid/vinyl-cache/apt/vinyl/t/dists/stable/f{n:04d}"
                for n in range(150)]
    raises(lambda: purge.batches(metadata), purge.PurgeError,
           "a signed metadata group may not span two purge requests")


def test_workflow_keeps_secrets_after_validation() -> None:
    root = Path(__file__).parents[1]
    workflow = (root / ".github/workflows/publish.yml").read_text()
    expect("container: ${{ needs.fetch.outputs.image }}" in workflow, "publisher uses the target utility container")
    expect("*-el10" not in workflow and "needs.fetch.outputs.publisher" in workflow,
           "workflow dispatch is driven by the validated route format")
    recheck = workflow.index("Recheck before secrets are used")
    install = workflow.index("Install container publication tools")
    publish = workflow.index("REPOSITORY_GPG_PRIVATE_KEY_B64:", recheck)
    expect(install < recheck < publish, "publication tools precede the recheck and secret-bearing step")
    expect("GITHUB_TOKEN: ${{ github.token }}" in workflow, "GitHub release fetch is authenticated")
    expect("retention-days: 1" in workflow, "unsigned package handoff has minimal retention")
    scripts = "\n".join(path.read_text() for path in (root / "scripts").glob("*.sh"))
    for forbidden in ("sync --delete", "trusted=yes", "gpgcheck=0", "repo_gpgcheck=0"):
        expect(forbidden not in scripts, f"forbidden publication option: {forbidden}")
    expect("--if-none-match '*'" in scripts, "immutable objects use atomic conditional creation")
    expect("Signature.*: OK$" in scripts, "RPM validation requires a verified OpenPGP signature")
    expect("*/vinyl-cache" in (root / "scripts/lib.sh").read_text(),
           "the public URL must name the fixed R2 object prefix")
    site_step = workflow[workflow.index("Publish the browsable site"):workflow.index("  smoke:")]
    site_workflow = (root / ".github/workflows/site.yml").read_text()
    for name in ("REPOSITORY_PUBLIC_URL", "REPOSITORY_GPG_FINGERPRINT", "R2_ACCOUNT_ID", "R2_BUCKET",
                 "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "CLOUDFLARE_ZONE_ID", "CLOUDFLARE_API_TOKEN"):
        declaration = f"{name}: ${{{{ secrets.{name} }}}}"
        expect(declaration in site_step, f"the site step must declare {name}")
        expect(declaration in site_workflow, f"the site workflow must declare {name}")
    expect(publish < workflow.index("Publish the browsable site"),
           "the site is generated after the repository tree it describes")
    for text, where in ((site_step, "publish.yml"), (site_workflow, "site.yml")):
        expect("REPOSITORY_GPG_PRIVATE_KEY_B64" not in text,
               f"the site step in {where} must not receive the signing key")
    expect(workflow.count("CLOUDFLARE_API_TOKEN") ==
           workflow[workflow.index("  publish:"):workflow.index("  smoke:")].count("CLOUDFLARE_API_TOKEN"),
           "the purge token stays inside the reviewer-gated publish job")
    expect("environment:\n      name: production" in site_workflow,
           "the site workflow runs in the protected environment")
    expect("group: vcache-repository-publish" in site_workflow,
           "the site workflow shares the publication concurrency group")
    for publisher in ("publish-apt.sh", "publish-rpm.sh"):
        expect((root / "scripts" / publisher).read_text().rstrip().endswith("\npurge_flush"),
               f"{publisher} must flush the recorded cache purge last")


def test_workflow_bootstraps_native_validation_and_container_actions() -> None:
    root = Path(__file__).parents[1]
    workflow = (root / ".github/workflows/publish.yml").read_text()
    fetch_checkout = workflow.index("- uses: actions/checkout")
    fetch_rpm = workflow.index("Install RPM metadata validator")
    fetch_release = workflow.index("Fetch and validate release")
    expect(fetch_rpm < fetch_release, "RPM metadata validator precedes release validation")
    expect(fetch_checkout < fetch_rpm, "fetch runner checks out before installing its RPM validator")

    publish = workflow[workflow.index("  publish:"):workflow.index("  smoke:")]
    bootstrap = publish.index("Bootstrap container action prerequisites")
    checkout = publish.index("- uses: actions/checkout")
    artifact = publish.index("actions/download-artifact")
    native_tools = publish.index("Install container publication tools")
    expect(bootstrap < checkout < artifact < native_tools,
           "target container bootstraps action prerequisites before checkout and artifact download")
    expect("apt-get install -y --no-install-recommends ca-certificates git" in publish,
           "Debian-family container bootstrap installs Git and CA certificates")
    expect("dnf -y install ca-certificates git-core" in publish,
           "EL container bootstrap installs Git and CA certificates")
    expect("awscli_version=2.33.0" in publish,
           "Debian-family publisher pins an AWS CLI version compatible with R2 conditional writes")
    expect("curl diffutils gnupg python3 reprepro unzip" in publish,
           "Debian-family publisher installs the byte-identity comparison tool")
    expect("awscli-exe-linux-${awscli_arch}-${awscli_version}.zip" in publish,
           "Debian-family publisher selects the official AWS CLI bundle by architecture")
    for digest in ("db9001fd76d322a2ce9c88b5e1f306c449137541c28d04ca076f3afce366d35d",
                   "317455780b0b3f88b34fd4112a34f98f02239340e3645437405a03750b132ffd"):
        expect(digest in publish, "Debian-family AWS CLI bundle checksum is pinned")
    expect('sha256sum --check --status' in publish and 'aws-cli/2.33.0*' in publish,
           "Debian-family publisher verifies the AWS CLI archive and installed version")
    expect('AWS CLI archive checksum mismatch' in publish,
           "Debian-family publisher reports an AWS CLI archive checksum mismatch without exposing data")


def test_smokes_retry_with_exact_installed_metadata() -> None:
    root = Path(__file__).parents[1]
    lib = (root / "scripts/lib.sh").read_text()
    apt = (root / "scripts/smoke-apt.sh").read_text()
    rpm = (root / "scripts/smoke-rpm.sh").read_text()
    expect("smoke_with_retries()" in lib, "smoke retry helper is missing")
    expect("SMOKE_ATTEMPTS:-6" in lib and "attempts -le 10" in lib,
           "smoke retries must have a bounded default")
    expect("SMOKE_RETRY_DELAY_SECONDS:-10" in lib and "delay -le 60" in lib,
           "smoke retry delay must be bounded")
    expect("smoke_with_retries docker run" in apt and "smoke_with_retries docker run" in rpm,
           "both public client smokes must retry in fresh containers")
    expect('expected=$(printf "%s\\t%s" "$expected_version" "$expected_architecture")' in apt and
           'dpkg-query -W -f="\\${Version}\\t\\${Architecture}"' in apt,
           "APT smoke must compare literal dpkg fields with an exact version and architecture")
    expect('expected_nevra=$(rpm -qp --qf "%{NEVRA}"' in rpm and
           'actual_nevra=$(rpm -q --qf "%{NEVRA}"' in rpm,
           "RPM smoke must compare the installed NEVRA")
    expect("dnf -y install epel-release\n  dnf -y makecache\n" in rpm,
           "RPM smoke must enable EPEL in a separate transaction before refreshing metadata")


def test_verify_workflow_lints_and_exercises_publishers() -> None:
    root = Path(__file__).parents[1]
    workflow = (root / ".github/workflows/verify.yml").read_text()
    expect("rhysd/actionlint@sha256:" in workflow, "workflow lint must use a pinned actionlint image")
    expect("koalaman/shellcheck@sha256:" in workflow, "shell lint must use a pinned ShellCheck image")
    expect("container: debian:13" in workflow and "test-publish-roundtrip.sh deb" in workflow,
           "verification must run the Debian publisher round trip in its native container")
    expect("container: almalinux:10" in workflow and "test-publish-roundtrip.sh rpm" in workflow,
           "verification must run the RPM publisher round trip in its native container")
    harness = (root / "scripts/test-publish-roundtrip.sh").read_text()
    expect(harness.count('"$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"') >= 2,
           "round trip must exercise immutable publication retries")
    expect("PURGE_DRY_RUN_FAIL=1" in harness,
           "round trip must prove a failed purge fails the publication and a rerun repairs it")
    expect("publish-site.sh" in harness and harness.count('"$REPO/scripts/publish-site.sh"') == 3,
           "round trip must prove the site is regenerated, skipped, and updated")
    expect("--if-none-match '*'" not in harness,
           "the mock object store must not replace the publisher's immutable-write assertion")
    apt_publisher = (root / "scripts/publish-apt.sh").read_text()
    expect("stage_package_by_digest" in apt_publisher and "cmp --silent" in apt_publisher,
           "APT publisher must prove generated pool packages are byte-identical to validated stage packages")
    expect('source_file="$STAGE/$base"' not in apt_publisher,
           "APT publisher must not rely on pool and release asset filenames matching")
    expect("vinyl-vmod-example_1.7-1.vinyl42.3.7.1_" in harness and
           "1.7-1~vinyl42.3.7.1" in harness,
           "APT round trip must cover GitHub-normalized VMOD filenames with Debian tilde versions")


def main() -> int:
    for test in (test_routes_and_tag, test_strict_checksums,
                 test_release_asset_names_reserve_handoff_markers, test_revision_order_inputs,
                 test_markdown_subset, test_site_generator, test_purge_batching,
                 test_workflow_keeps_secrets_after_validation,
                 test_workflow_bootstraps_native_validation_and_container_actions,
                 test_smokes_retry_with_exact_installed_metadata,
                 test_verify_workflow_lints_and_exercises_publishers):
        test()
        print(f"ok - {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
