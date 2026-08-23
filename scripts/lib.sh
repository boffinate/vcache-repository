#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Payloads are immutable, so they may be cached forever. Everything a client
# re-reads to discover new packages is capped short enough that a failed purge
# is bounded staleness rather than a stuck repository.
CACHE_IMMUTABLE='public, max-age=31536000, immutable'
CACHE_METADATA='public, max-age=600'
CACHE_KEYRING='public, max-age=3600'
CACHE_HTML='public, max-age=600'

die() { echo "error: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_env() { [[ -n ${!1:-} ]] || die "missing environment variable: $1"; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
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

purge_record() {
  local path=${1#vinyl-cache/} base=${REPOSITORY_PUBLIC_URL%/}
  printf '%s\n' "$base/$path" >>"${PURGE_LIST:?}"
  # A Transform Rule rewrites the directory URL a browser asks for onto the
  # index.html object, and Cloudflare caches under the requested URL.
  if [[ $path == index.html || $path == */index.html ]]; then
    printf '%s\n' "$base/${path%index.html}" >>"$PURGE_LIST"
  fi
}

purge_flush() {
  [[ -s ${PURGE_LIST:?} ]] || return 0
  need python3
  python3 "$ROOT/tools/purge.py" --urls-file "$PURGE_LIST"
}
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
r2_put() { aws "${AWS_ARGS[@]}" s3 cp "$1" "$(r2_uri "$2")" --only-show-errors --content-type "$3" --cache-control "${4:?}"; purge_record "$2"; }

# Single-part put keeps the stored ETag a plain MD5, which is what site.py
# compares against to skip pages whose bytes have not changed.
r2_put_html() {
  local file=$1 key=$2 size
  size=$(wc -c <"$file")
  (( size <= 5242880 )) || die "generated page is too large for a single-part upload: $key"
  aws "${AWS_ARGS[@]}" s3api put-object --bucket "$R2_BUCKET" --key "$key" --body "$file" --content-type 'text/html; charset=utf-8' --cache-control "$CACHE_HTML" >/dev/null
  purge_record "$key"
}

r2_immutable_once() {
  local source=$1 key=$2 expected=$3 content_type=$4 cache_control=$5 collision=$6 existing output actual
  if output=$(aws "${AWS_ARGS[@]}" s3api put-object --bucket "$R2_BUCKET" --key "$key" --body "$source" --content-type "$content_type" --cache-control "$cache_control" --if-none-match '*' 2>&1); then
    purge_record "$key"
    return
  fi
  grep -Eqi '(^|[^0-9])412([^0-9]|$)|preconditionfailed' <<<"$output" || { printf '%s\n' "$output" >&2; die "could not create immutable object: $key"; }
  existing=$(mktemp)
  r2_get "$existing" "$key"
  actual=$(sha256_file "$existing")
  [[ $actual == "$expected" ]] || { rm -f "$existing"; die "$collision"; }
  rm -f "$existing"
  # The object is already correct, but the URL may be cached as a 404 from a
  # probe taken before it existed, and a rerun after a failed purge must
  # re-record everything the previous run touched. The existing object's
  # metadata is deliberately left alone: payloads are never overwritten, so a
  # legacy object simply keeps whatever headers it was created with.
  purge_record "$key"
}

r2_public_key_once() {
  r2_immutable_once "$1" "$2" "$(sha256_file "$1")" "application/pgp-keys" "$CACHE_KEYRING" "public key object differs from checked-in certificate"
}

r2_package_once() {
  r2_immutable_once "$1" "$2" "$3" "application/octet-stream" "$CACHE_IMMUTABLE" "immutable package collision at $2; bump package_revision"
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

smoke_setup() {
  [[ $# -eq 3 ]] || die "usage: $0 <validated-stage> <repository-public-url>"
  STAGE=$(CDPATH= cd -- "$2" && pwd)
  REPOSITORY_PUBLIC_URL=${3%/}
  check_public_url
  stage_route "$STAGE"
  [[ $FORMAT == "$1" ]] || die "stage format is $FORMAT, expected $1"
  need docker; need_env REPOSITORY_GPG_FINGERPRINT
}

smoke_with_retries() {
  local attempts=${SMOKE_ATTEMPTS:-6} delay=${SMOKE_RETRY_DELAY_SECONDS:-10} attempt rc
  [[ $attempts =~ ^[1-9][0-9]*$ && $attempts -le 10 ]] || die "SMOKE_ATTEMPTS must be an integer from 1 to 10"
  [[ $delay =~ ^[0-9]+$ && $delay -le 60 ]] || die "SMOKE_RETRY_DELAY_SECONDS must be an integer from 0 to 60"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if (( attempt < attempts )); then
      printf 'public repository smoke attempt %d/%d failed; retrying in %ss\n' "$attempt" "$attempts" "$delay" >&2
      sleep "$delay"
    fi
  done
  printf 'public repository smoke failed after %d attempts\n' "$attempts" >&2
  return "$rc"
}

upload_tree() {
  local tree=$1 prefix=$2 file rel skip
  shift 2
  while IFS= read -r -d '' file; do
    rel=${file#"$tree"/}
    for skip; do [[ $rel == "$skip" ]] && continue 2; done
    r2_put "$file" "$prefix/$rel" "application/octet-stream" "$CACHE_METADATA"
  done < <(find "$tree" -type f -print0 | sort -z)
}
