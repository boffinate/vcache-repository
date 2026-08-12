#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"
smoke_setup deb "$@"
URL=$REPOSITORY_PUBLIC_URL
docker run --rm --platform "$PLATFORM" -v "$STAGE:/stage:ro" "$IMAGE" bash -euxo pipefail -c '
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --silent --show-error "$0/vcache-archive-keyring.asc" -o /etc/apt/keyrings/vcache-archive-keyring.asc
  test "$(gpg --show-keys --with-colons /etc/apt/keyrings/vcache-archive-keyring.asc | awk -F: '\''$1 == "fpr" {print $10; exit}'\'')" = "$1"
  curl --fail --silent --show-error "$0/apt/$2/$3/vcache-$2.sources" -o /etc/apt/sources.list.d/vcache.sources
  apt-get update
  packages=$(for file in /stage/*.deb; do dpkg-deb -f "$file" Package; done)
  apt-get install -y $packages
' "$URL" "$REPOSITORY_GPG_FINGERPRINT" "$FAMILY" "$TARGET"
