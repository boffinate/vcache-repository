#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROUTES=${ROUTES:-$ROOT/routes.tsv}

die() { echo "error: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_env() { [[ -n ${!1:-} ]] || die "missing environment variable: $1"; }
check_public_url() {
  need_env REPOSITORY_PUBLIC_URL
  local normal=${REPOSITORY_PUBLIC_URL,,}
  [[ $REPOSITORY_PUBLIC_URL == https://* ]] || die "REPOSITORY_PUBLIC_URL must use HTTPS"
  [[ $normal != *r2.dev* ]] || die "r2.dev is for development only"
  [[ ${REPOSITORY_PUBLIC_URL%/} == */vinyl-cache ]] || die "REPOSITORY_PUBLIC_URL must end in /vinyl-cache"
}

stage_route() {
  local line
  line=$("$ROOT/scripts/fetch-release.sh" --describe "$1") || die "could not describe validated stage"
  IFS=$'\t' read -r FAMILY TARGET FORMAT ARCH IMAGE PLATFORM <<<"$line"
  [[ -n $FAMILY && -n $TARGET && -n $FORMAT && -n $ARCH && -n $IMAGE && -n $PLATFORM ]] || die "incomplete route"
}

r2_setup() {
  need aws
  need_env R2_ACCOUNT_ID; need_env R2_BUCKET; need_env R2_ACCESS_KEY_ID; need_env R2_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION=auto
  R2_ENDPOINT=https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com
  AWS_ARGS=(--endpoint-url "$R2_ENDPOINT" --no-cli-pager)
}

r2_uri() { printf 's3://%s/%s' "$R2_BUCKET" "$1"; }
r2_exists() {
  local output rc
  if output=$(aws "${AWS_ARGS[@]}" s3api head-object --bucket "$R2_BUCKET" --key "$1" 2>&1); then
    return 0
  else
    rc=$?
  fi
  if grep -Eqi '(^|[^0-9])404([^0-9]|$)|not[[:space:]]+found|nosuchkey' <<<"$output"; then
    return 1
  fi
  printf '%s\n' "$output" >&2
  return "$rc"
}
r2_get() { aws "${AWS_ARGS[@]}" s3 cp "$(r2_uri "$2")" "$1" --only-show-errors; }
r2_put() { aws "${AWS_ARGS[@]}" s3 cp "$1" "$(r2_uri "$2")" --only-show-errors --content-type "$3"; }

r2_immutable_once() {
  local source=$1 key=$2 expected=$3 content_type=$4 collision=$5 existing rc actual
  if r2_exists "$key"; then
    existing=$(mktemp)
    r2_get "$existing" "$key"
    actual=$(sha256sum "$existing" | awk '{print $1}')
    [[ $actual == "$expected" ]] || { rm -f "$existing"; die "$collision"; }
    rm -f "$existing"
  else
    rc=$?
    (( rc == 1 )) || die "could not check immutable object: $key"
    r2_put "$source" "$key" "$content_type"
  fi
}

r2_public_key_once() {
  r2_immutable_once "$1" "$2" "$(sha256sum "$1" | awk '{print $1}')" "application/pgp-keys" "public key object differs from checked-in certificate"
}

r2_package_once() {
  r2_immutable_once "$1" "$2" "$3" "application/octet-stream" "immutable package collision at $2; bump package_revision"
}

decode_private_key() {
  local destination=$1
  need python3
  printf '%s' "$REPOSITORY_GPG_PRIVATE_KEY_B64" | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))' >"$destination" || die "invalid base64 private key"
  chmod 600 "$destination"
}

gpg_setup() {
  need gpg
  need_env REPOSITORY_GPG_PRIVATE_KEY_B64
  need_env REPOSITORY_GPG_FINGERPRINT
  [[ $# -eq 1 ]] || die "gpg_setup requires a temporary home"
  export GNUPGHOME=$1
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  local keyfile="$GNUPGHOME/private.key"
  decode_private_key "$keyfile"
  gpg --batch --import "$keyfile" >/dev/null
  rm -f "$keyfile"
  local actual
  actual=$(gpg --batch --with-colons --list-keys "$REPOSITORY_GPG_FINGERPRINT" | awk -F: '$1 == "fpr" {print $10; exit}')
  [[ $actual == "$REPOSITORY_GPG_FINGERPRINT" ]] || die "configured GPG fingerprint is not present"
  local secret
  secret=$(gpg --batch --with-colons --list-secret-keys "$REPOSITORY_GPG_FINGERPRINT" | awk -F: '$1 == "fpr" {print $10; exit}')
  [[ $secret == "$REPOSITORY_GPG_FINGERPRINT" ]] || die "configured fingerprint is not the imported secret primary key"
  gpg --batch --with-colons --list-secret-keys "$REPOSITORY_GPG_FINGERPRINT" | awk -F: '($1 == "sec" || $1 == "ssb") && $12 ~ /s/ {found=1} END {exit !found}' || die "imported secret key has no signing capability"
  gpg --batch --with-colons --list-keys "$REPOSITORY_GPG_FINGERPRINT" | awk -F: '$1 == "pub" && ($2 ~ /[re]/ || ($7 != "" && $7 != "0" && $7 < systime())) {bad=1} END {exit bad}' || die "archive key is expired or revoked"
}

verify_public_key() {
  local key=$1 actual
  actual=$(gpg --batch --show-keys --with-colons "$key" | awk -F: '$1 == "fpr" {print $10; exit}')
  [[ $actual == "$REPOSITORY_GPG_FINGERPRINT" ]] || die "checked-in public key fingerprint mismatch"
}

upload_tree() {
  local tree=$1 prefix=$2 file rel skip
  shift 2
  while IFS= read -r -d '' file; do
    rel=${file#"$tree"/}
    for skip; do [[ $rel == "$skip" ]] && continue 2; done
    r2_put "$file" "$prefix/$rel" "application/octet-stream"
  done < <(find "$tree" -type f -print0 | sort -z)
}
