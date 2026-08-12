#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"
[[ $# -eq 2 ]] || die "usage: $0 <validated-stage> <repository-public-url>"
STAGE=$(CDPATH= cd -- "$1" && pwd)
URL=${2%/}
REPOSITORY_PUBLIC_URL=$URL
check_public_url
stage_route "$STAGE"
[[ $FORMAT == rpm ]] || die "not an RPM target"
need docker
docker run --rm --platform "$PLATFORM" -v "$STAGE:/stage:ro" "$IMAGE" bash -euxo pipefail -c '
  dnf -y install ca-certificates curl-minimal gnupg2
  /usr/bin/curl --fail --silent --show-error "$0/vcache-archive-keyring.asc" -o /etc/pki/rpm-gpg/vcache-archive-keyring.asc
  test "$(gpg --show-keys --with-colons /etc/pki/rpm-gpg/vcache-archive-keyring.asc | awk -F: '\''$1 == "fpr" {print $10; exit}'\'')" = "$3"
  /usr/bin/curl --fail --silent --show-error "$0/rpm/$1/vcache-$1.repo" -o /etc/yum.repos.d/vcache.repo
  grep -q "gpgcheck=1" /etc/yum.repos.d/vcache.repo
  grep -q "repo_gpgcheck=1" /etc/yum.repos.d/vcache.repo
  dnf -y makecache
  packages=$(for file in /stage/*.rpm; do rpm -qp --qf "%{NAME}\n" "$file"; done)
  dnf -y install $packages
' "$URL" "$FAMILY" "$TARGET" "$REPOSITORY_GPG_FINGERPRINT"
