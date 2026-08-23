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
    expect(harness.count('"$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"') == 2,
           "round trip must exercise immutable publication retries")
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
                 test_workflow_keeps_secrets_after_validation,
                 test_workflow_bootstraps_native_validation_and_container_actions,
                 test_smokes_retry_with_exact_installed_metadata,
                 test_verify_workflow_lints_and_exercises_publishers):
        test()
        print(f"ok - {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
