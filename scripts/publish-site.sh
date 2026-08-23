#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 0 ]] || die "usage: $0"
need python3
need_env REPOSITORY_GPG_FINGERPRINT
check_public_url
r2_setup

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PURGE_LIST="$TMP/purge-urls"
: >"$PURGE_LIST"
LISTING="$TMP/listing.json"
SITE="$TMP/site"
PACKAGES="$TMP/packages"
mkdir -p "$SITE" "$PACKAGES"

# The CLI paginates this call itself. Never add --no-paginate: a truncated
# listing would silently drop entries from every page it generates.
aws "${AWS_ARGS[@]}" s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix vinyl-cache/ --output json >"$LISTING"

python3 "$ROOT/tools/site.py" packages --listing "$LISTING" >"$TMP/packages-keys"
while IFS= read -r key; do
  mkdir -p "$PACKAGES/${key%/*}"
  r2_get "$PACKAGES/$key" "$key"
done <"$TMP/packages-keys"

python3 "$ROOT/tools/site.py" build \
  --listing "$LISTING" \
  --routes "$ROOT/routes.tsv" \
  --readme "$ROOT/README.md" \
  --template "$ROOT/site/page.html.tmpl" \
  --packages-dir "$PACKAGES" \
  --fingerprint "$REPOSITORY_GPG_FINGERPRINT" \
  --out "$SITE"
python3 "$ROOT/tools/site.py" plan --listing "$LISTING" --site "$SITE" >"$TMP/plan"

while IFS=$'\t' read -r action key; do
  [[ $action == upload ]] || continue
  r2_put_html "$SITE/$key" "$key"
done <"$TMP/plan"
purge_flush
