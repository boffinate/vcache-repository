#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <validated-stage>"
STAGE=$(CDPATH= cd -- "$1" && pwd)
stage_route "$STAGE"
[[ $FORMAT == deb ]] || die "source tag is not a Debian target"
need reprepro; need dpkg-deb; need sha256sum; need cmp
check_public_url
"$SCRIPT_DIR/fetch-release.sh" --verify "$STAGE" >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PURGE_LIST="$TMP/purge-urls"
: >"$PURGE_LIST"
TREE="$TMP/tree"
mkdir -p "$TREE/conf" "$TREE/dists" "$TREE/pool"
printf '%s\n' "Origin: vcache-packaging" "Label: vcache-$FAMILY" "Codename: stable" "Suite: stable" "Components: main" "Architectures: $ARCH" "SignWith: $REPOSITORY_GPG_FINGERPRINT" >"$TREE/conf/distributions"

gpg_setup "$TMP/gnupg"
verify_public_key "$ROOT/keys/vcache-archive-keyring.asc"

shopt -s nullglob
packages=("$STAGE"/*.deb)
(( ${#packages[@]} > 0 )) || die "no Debian packages in stage"
declare -A stage_package_by_digest
for package in "${packages[@]}"; do
  digest=$(sha256_file "$package")
  existing=${stage_package_by_digest[$digest]:-}
  if [[ -n $existing ]]; then
    cmp --silent "$existing" "$package" || die "validated stage has colliding package digests"
  else
    stage_package_by_digest[$digest]=$package
  fi
  reprepro -b "$TREE" includedeb stable "$package" >/dev/null
done

# index.html is reserved for the generated site, so a repository tree that
# contained one would have its listing page silently replaced by package data.
[[ -z $(find "$TREE" -name index.html -print -quit) ]] || die "generated tree contains a reserved index.html"

release="$TREE/dists/stable/Release"
inrelease="$TREE/dists/stable/InRelease"
release_sig="$TREE/dists/stable/Release.gpg"
[[ -s "$release" && -s "$inrelease" && -s "$release_sig" ]] || die "reprepro did not create all signed metadata"
gpg --batch --verify "$release_sig" "$release" >/dev/null
gpg --batch --verify "$inrelease" >/dev/null

CLIENT="$TMP/vcache-$FAMILY.sources"
cat >"$CLIENT" <<EOF
Types: deb
URIs: ${REPOSITORY_PUBLIC_URL%/}/apt/$FAMILY/$TARGET
Suites: stable
Components: main
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/vcache-archive-keyring.asc
EOF

PREFIX="vinyl-cache/apt/$FAMILY/$TARGET"
r2_setup
r2_public_key_once "$ROOT/keys/vcache-archive-keyring.asc" "vinyl-cache/vcache-archive-keyring.asc"
while IFS= read -r -d '' pool_file; do
  expected=$(sha256_file "$pool_file")
  source_file=${stage_package_by_digest[$expected]:-}
  [[ -n $source_file ]] || die "generated pool file does not match a validated stage package"
  cmp --silent "$source_file" "$pool_file" || die "generated pool file differs from its validated stage package"
  r2_package_once "$pool_file" "$PREFIX/${pool_file#"$TREE"/}" "$expected"
done < <(find "$TREE/pool" -type f -print0 | sort -z)

upload_tree "$TREE/dists" "$PREFIX/dists" "stable/Release" "stable/Release.gpg" "stable/InRelease"
r2_put "$CLIENT" "$PREFIX/vcache-$FAMILY.sources" "text/plain" "$CACHE_METADATA"
r2_put "$release" "$PREFIX/dists/stable/Release" "application/octet-stream" "$CACHE_METADATA"
r2_put "$release_sig" "$PREFIX/dists/stable/Release.gpg" "application/pgp-signature" "$CACHE_METADATA"
r2_put "$inrelease" "$PREFIX/dists/stable/InRelease" "application/octet-stream" "$CACHE_METADATA"
purge_flush
