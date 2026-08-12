#!/usr/bin/env python3
"""Host-safe tests for the release and route public seams."""
import hashlib
import tempfile
from pathlib import Path

import release


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def rejects(call, message: str) -> None:
    try:
        call()
    except release.ValidationError:
        return
    raise AssertionError(message)


def test_routes_and_tag() -> None:
    table = release.routes(Path(__file__).parents[1] / "routes.tsv")
    family, target, route = release.route_for_tag("vinyl-42.3.7-debian-13-amd64", table)
    expect((family, target, route["format"], route["arch"]) == ("vinyl", "debian-13-amd64", "deb", "amd64"), "route resolution")
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


def test_workflow_keeps_secrets_after_validation() -> None:
    root = Path(__file__).parents[1]
    workflow = (root / ".github/workflows/publish.yml").read_text()
    expect("container: ${{ needs.fetch.outputs.image }}" in workflow, "publisher uses the target utility container")
    expect("*-el10" not in workflow and "needs.fetch.outputs.publisher" in workflow,
           "workflow dispatch is driven by the validated route format")
    recheck = workflow.index("Recheck before secrets are used")
    publish = workflow.index("REPOSITORY_GPG_PRIVATE_KEY_B64:", recheck)
    expect(recheck < publish, "validated transfer is rechecked before the secret-bearing step")
    scripts = "\n".join(path.read_text() for path in (root / "scripts").glob("*.sh"))
    for forbidden in ("sync --delete", "trusted=yes", "gpgcheck=0", "repo_gpgcheck=0"):
        expect(forbidden not in scripts, f"forbidden publication option: {forbidden}")
    expect("*/vinyl-cache" in (root / "scripts/lib.sh").read_text(),
           "the public URL must name the fixed R2 object prefix")


def main() -> int:
    for test in (test_routes_and_tag, test_strict_checksums,
                 test_release_asset_names_reserve_handoff_markers, test_revision_order_inputs,
                 test_workflow_keeps_secrets_after_validation):
        test()
        print(f"ok - {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
