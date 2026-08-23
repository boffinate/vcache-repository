#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <validated-stage>"
STAGE=$(CDPATH= cd -- "$1" && pwd)
stage_route "$STAGE"
[[ $FORMAT == rpm ]] || die "source tag is not an RPM target"
need rpm; need rpmkeys; need rpmsign; need createrepo_c; need sha256sum
check_public_url
"$SCRIPT_DIR/fetch-release.sh" --verify "$STAGE" >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PURGE_LIST="$TMP/purge-urls"
: >"$PURGE_LIST"
TREE="$TMP/tree"
RPMDB="$TMP/rpmdb"
mkdir -p "$TREE/Packages" "$RPMDB"

verify_rpm_signature() {
  local package=$1 output
  output=$(LC_ALL=C rpmkeys --dbpath "$RPMDB" --checksig --verbose "$package") || die "RPM signature is invalid: ${package##*/}"
  grep -Eq 'Signature.*: OK$' <<<"$output" || die "RPM has no verified OpenPGP signature: ${package##*/}"
}

gpg_setup "$TMP/gnupg"
verify_public_key "$ROOT/keys/vcache-archive-keyring.asc"
rpm --dbpath "$RPMDB" --import "$ROOT/keys/vcache-archive-keyring.asc"
r2_setup

shopt -s nullglob
packages=("$STAGE"/*.rpm)
(( ${#packages[@]} > 0 )) || die "no RPM packages in stage"
for source in "${packages[@]}"; do
  base=${source##*/}
  source_meta=$(rpm -qp --qf '%{NEVRA}\t%{SHA256HEADER}\t%{PAYLOADDIGEST}\n' "$source")
  signed="$TREE/Packages/$base"
  object_key="vinyl-cache/rpm/$FAMILY/$TARGET/Packages/$base"
  if r2_exists "$object_key"; then
    existing="$TMP/existing-$base"
    r2_get "$existing" "$object_key"
    existing_meta=$(rpm -qp --qf '%{NEVRA}\t%{SHA256HEADER}\t%{PAYLOADDIGEST}\n' "$existing") || die "existing RPM object is unreadable: $base"
    [[ $existing_meta == "$source_meta" ]] || die "immutable RPM collision at $object_key; bump package_revision"
    verify_rpm_signature "$existing"
    cp "$existing" "$signed"
  else
    rc=$?
    (( rc == 1 )) || die "could not check immutable RPM object: $object_key"
    cp "$source" "$signed"
    rpmsign --define "_gpg_name $REPOSITORY_GPG_FINGERPRINT" --addsign "$signed" >/dev/null
    verify_rpm_signature "$signed"
  fi
done

createrepo_c "$TREE" >/dev/null
gpg --batch --armor --detach-sign --local-user "$REPOSITORY_GPG_FINGERPRINT" --output "$TREE/repodata/repomd.xml.asc" "$TREE/repodata/repomd.xml"
gpg --batch --verify "$TREE/repodata/repomd.xml.asc" "$TREE/repodata/repomd.xml" >/dev/null

# index.html is reserved for the generated site, so a repository tree that
# contained one would have its listing page silently replaced by package data.
[[ -z $(find "$TREE" -name index.html -print -quit) ]] || die "generated tree contains a reserved index.html"

CLIENT="$TMP/vcache-$FAMILY.repo"
target_pattern=${TARGET%-"$ARCH"}'-$basearch'
cat >"$CLIENT" <<EOF
[vcache-$FAMILY]
name=Current $FAMILY packages from vcache-packaging
baseurl=${REPOSITORY_PUBLIC_URL%/}/rpm/$FAMILY/$target_pattern
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${REPOSITORY_PUBLIC_URL%/}/vcache-archive-keyring.asc
sslverify=1
EOF

PREFIX="vinyl-cache/rpm/$FAMILY/$TARGET"
r2_public_key_once "$ROOT/keys/vcache-archive-keyring.asc" "vinyl-cache/vcache-archive-keyring.asc"
while IFS= read -r -d '' signed; do
  base=${signed##*/}
  r2_package_once "$signed" "$PREFIX/Packages/$base" "$(sha256_file "$signed")"
done < <(find "$TREE/Packages" -type f -print0 | sort -z)
while IFS= read -r -d '' file; do
  rel=${file#"$TREE"/}
  [[ $rel == repodata/repomd.xml || $rel == repodata/repomd.xml.asc ]] && continue
  r2_put "$file" "$PREFIX/$rel" "application/octet-stream" "$CACHE_METADATA"
done < <(find "$TREE/repodata" -type f -print0 | sort -z)
r2_put "$CLIENT" "vinyl-cache/rpm/$FAMILY/vcache-$FAMILY.repo" "text/plain" "$CACHE_METADATA"
r2_put "$TREE/repodata/repomd.xml" "$PREFIX/repodata/repomd.xml" "application/xml" "$CACHE_METADATA"
r2_put "$TREE/repodata/repomd.xml.asc" "$PREFIX/repodata/repomd.xml.asc" "application/pgp-signature" "$CACHE_METADATA"
purge_flush
