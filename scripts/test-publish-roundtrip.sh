#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FORMAT=${1:-}
[[ $FORMAT == deb || $FORMAT == rpm ]] || { echo "usage: $0 <deb|rpm>" >&2; exit 2; }

TMP=$(mktemp -d)
SERVER=
trap '[[ -z $SERVER ]] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
REPO="$TMP/repository"
STAGE="$TMP/stage"
NEXT_STAGE="$TMP/stage-next"
STORE="$TMP/object-store"
HEADERS="$TMP/object-headers"
PURGE="$TMP/purge"
CALLS="$TMP/calls"
MOCK_BIN="$TMP/bin"
mkdir -p "$REPO" "$STAGE" "$NEXT_STAGE" "$STORE" "$HEADERS" "$PURGE" "$CALLS" "$MOCK_BIN"
cp -a "$ROOT/." "$REPO"

fail() { echo "assertion failed: $*" >&2; exit 1; }

cat >"$MOCK_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ ${1:-} == --* ]]; do
  case $1 in
    --endpoint-url) shift 2 ;;
    --no-cli-pager) shift ;;
    *) echo "unexpected AWS option: $1" >&2; exit 2 ;;
  esac
done
command=$1
shift
store=${MOCK_R2_DIR:?}
headers=${MOCK_R2_HEADERS:?}
key_from_uri() { printf '%s' "${1#s3://*/}"; }
# Stored metadata lives outside the object store so it can never be mistaken
# for an object by the bucket listing.
store_headers() {
  local key=$1 path="$headers/$1"
  mkdir -p "${path%/*}"
  printf '%s\n%s\n' "$2" "$3" >"$path"
  [[ -z ${MOCK_R2_LOG:-} ]] || printf '%s\t%s\n' "$4" "$key" >>"$MOCK_R2_LOG"
}
case $command in
  s3api)
    operation=$1
    shift
    case $operation in
      head-object|put-object|list-objects-v2) ;;
      *) echo "unexpected AWS s3api operation: $operation" >&2; exit 2 ;;
    esac
    key= body= content_type= cache_control= prefix= conditional=0
    while (($#)); do
      case $1 in
        --bucket) shift 2 ;;
        --key) key=$2; shift 2 ;;
        --body) body=$2; shift 2 ;;
        --content-type) content_type=$2; shift 2 ;;
        --cache-control) cache_control=$2; shift 2 ;;
        --prefix) prefix=$2; shift 2 ;;
        --output) shift 2 ;;
        --if-none-match) conditional=1; shift 2 ;;
        *) echo "unexpected AWS argument: $1" >&2; exit 2 ;;
      esac
    done
    case $operation in
      head-object)
        [[ -f "$store/$key" ]] && exit 0
        echo "404 Not Found" >&2
        exit 255
        ;;
      list-objects-v2)
        exec python3 - "$store" "$prefix" <<'PY'
import datetime
import hashlib
import json
import os
import sys

store, prefix = sys.argv[1], sys.argv[2]
contents = []
for directory, _, names in os.walk(store):
    for name in names:
        path = os.path.join(directory, name)
        key = os.path.relpath(path, store)
        if not key.startswith(prefix):
            continue
        data = open(path, "rb").read()
        modified = datetime.datetime.fromtimestamp(int(os.path.getmtime(path)), datetime.timezone.utc)
        contents.append({
            "Key": key,
            "Size": len(data),
            "LastModified": modified.strftime("%Y-%m-%dT%H:%M:%S+00:00"),
            "ETag": '"%s"' % hashlib.md5(data, usedforsecurity=False).hexdigest(),
        })
contents.sort(key=lambda item: item["Key"])
print(json.dumps({"Contents": contents}, indent=4))
PY
        ;;
    esac
    path="$store/$key"
    if (( conditional )) && [[ -e $path ]]; then
      echo "PreconditionFailed" >&2
      exit 1
    fi
    mkdir -p "${path%/*}"
    cp "$body" "$path"
    store_headers "$key" "$content_type" "$cache_control" put-object
    printf '{"ETag":"\\"%s\\""}\n' "$(md5sum "$path" | awk '{print $1}')"
    ;;
  s3)
    [[ $1 == cp ]] || exit 2
    shift
    content_type= cache_control=
    positional=()
    while (($#)); do
      case $1 in
        --only-show-errors) shift ;;
        --content-type) content_type=$2; shift 2 ;;
        --cache-control) cache_control=$2; shift 2 ;;
        --*) echo "unexpected AWS argument: $1" >&2; exit 2 ;;
        *) positional+=("$1"); shift ;;
      esac
    done
    (( ${#positional[@]} == 2 )) || { echo "unexpected AWS copy arguments" >&2; exit 2; }
    source=${positional[0]} destination=${positional[1]}
    if [[ $source == s3://* ]]; then
      cp "$store/$(key_from_uri "$source")" "$destination"
    else
      key=$(key_from_uri "$destination")
      path="$store/$key"
      mkdir -p "${path%/*}"
      cp "$source" "$path"
      store_headers "$key" "$content_type" "$cache_control" cp
    fi
    ;;
  *) echo "unexpected AWS command: $command" >&2; exit 2 ;;
esac
EOF
chmod +x "$MOCK_BIN/aws"

GNUPGHOME="$TMP/keygen"
export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key 'Repository test key <test@example.invalid>' rsa2048 sign 0
FINGERPRINT=$(gpg --batch --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}')
gpg --batch --armor --export "$FINGERPRINT" >"$REPO/keys/vcache-archive-keyring.asc"
PRIVATE_KEY_B64=$(gpg --batch --export-secret-keys "$FINGERPRINT" | base64 | tr -d '\n')
unset GNUPGHOME

# The generated root page repeats the README fingerprint, so the throwaway test
# key has to be the one the copied README advertises.
python3 - "$REPO/README.md" "$FINGERPRINT" <<'PY'
import re
import sys

path, fingerprint = sys.argv[1], sys.argv[2]
text = open(path).read()
open(path, "w").write(re.sub(r"\b[0-9A-F]{40}\b", fingerprint, text))
PY

build_deb() {
  local version=$1 destination=$2
  local root="$TMP/package-$version"
  mkdir -p "$root/DEBIAN"
  cat >"$root/DEBIAN/control" <<EOF
Package: vinyl-cache
Version: $version
Architecture: $DEB_ARCH
Maintainer: Repository test <test@example.invalid>
Section: admin
Priority: optional
Description: Repository publisher test package
EOF
  dpkg-deb --build "$root" "$destination/vinyl-cache_${version}_$DEB_ARCH.deb" >/dev/null
}

build_rpm() {
  local revision=$1 destination=$2
  local topdir="$TMP/rpmbuild-$revision"
  mkdir -p "$topdir/SPECS"
  cat >"$topdir/SPECS/vinyl-cache.spec" <<EOF
Name: vinyl-cache
Version: 42.3.7
Release: $revision
Summary: Repository publisher test package
License: BSD-2-Clause
BuildArch: $RPM_ARCH

%description
Repository publisher test package.

%install
mkdir -p %{buildroot}/usr/share/vinyl-cache
printf 'test\n' > %{buildroot}/usr/share/vinyl-cache/test

%files
/usr/share/vinyl-cache/test
EOF
  rpmbuild --define "_topdir $topdir" -bb "$topdir/SPECS/vinyl-cache.spec" >/dev/null
  cp "$topdir/RPMS/$RPM_ARCH/vinyl-cache-42.3.7-$revision.$RPM_ARCH.rpm" "$destination/"
}

seal_stage() {
  local stage=$1 package packages
  mapfile -t packages < <(find "$stage" -maxdepth 1 -type f -name "*.$FORMAT" -printf '%f\n' | sort)
  (( ${#packages[@]} > 0 ))
  for package in "${packages[@]}"; do
    printf '%s  %s\n' "$(sha256sum "$stage/$package" | awk '{print $1}')" "$package"
  done >"$stage/SHA256SUMS"
  printf '%s\n' "$TAG" >"$stage/.source-tag"
  printf 'ok\n' >"$stage/.validated"
  python3 "$REPO/tools/release.py" verify --stage "$stage" --routes "$REPO/routes.tsv"
}

if [[ $FORMAT == deb ]]; then
  DEB_ARCH=$(dpkg --print-architecture)
  case $DEB_ARCH in
    amd64|arm64) DEB_TARGET="debian-13-$DEB_ARCH" ;;
    *) echo "unsupported Debian test architecture: $DEB_ARCH" >&2; exit 2 ;;
  esac
  build_deb 42.3.7-1 "$STAGE"
  VMOD_ROOT="$TMP/vmod-package"
  mkdir -p "$VMOD_ROOT/DEBIAN"
  cat >"$VMOD_ROOT/DEBIAN/control" <<EOF
Package: vinyl-vmod-example
Version: 1.7-1~vinyl42.3.7.1
Architecture: $DEB_ARCH
Maintainer: Repository test <test@example.invalid>
Section: admin
Priority: optional
Description: Repository publisher test VMOD
EOF
  dpkg-deb --build "$VMOD_ROOT" "$STAGE/vinyl-vmod-example_1.7-1.vinyl42.3.7.1_$DEB_ARCH.deb" >/dev/null
  TAG=vinyl-42.3.7-$DEB_TARGET
  PUBLISHER=apt
  PREFIX_KEY="vinyl-cache/apt/vinyl/$DEB_TARGET"
  CLIENT_KEY="$PREFIX_KEY/vcache-vinyl.sources"
  METADATA_KEY="$PREFIX_KEY/dists/stable/InRelease"
  METADATA_DIR="$PREFIX_KEY/dists/"
  PAYLOAD_GLOB="$STORE/$PREFIX_KEY/pool"
  build_deb 42.3.7-2 "$NEXT_STAGE"
else
  RPM_ARCH=$(rpm --eval '%{_arch}')
  case $RPM_ARCH in
    x86_64) RPM_TARGET=el10-x86_64 ;;
    aarch64) RPM_TARGET=el10-aarch64 ;;
    *) echo "unsupported RPM test architecture: $RPM_ARCH" >&2; exit 2 ;;
  esac
  build_rpm 1 "$STAGE"
  TAG=vinyl-42.3.7-$RPM_TARGET
  PUBLISHER=rpm
  PREFIX_KEY="vinyl-cache/rpm/vinyl/$RPM_TARGET"
  CLIENT_KEY="vinyl-cache/rpm/vinyl/vcache-vinyl.repo"
  METADATA_KEY="$PREFIX_KEY/repodata/repomd.xml"
  METADATA_DIR="$PREFIX_KEY/repodata/"
  PAYLOAD_GLOB="$STORE/$PREFIX_KEY/Packages"
  build_rpm 2 "$NEXT_STAGE"
fi
seal_stage "$STAGE"
seal_stage "$NEXT_STAGE"

export PATH="$MOCK_BIN:$PATH"
export MOCK_R2_DIR="$STORE"
export MOCK_R2_HEADERS="$HEADERS"
export REPOSITORY_GPG_PRIVATE_KEY_B64="$PRIVATE_KEY_B64"
export REPOSITORY_GPG_FINGERPRINT="$FINGERPRINT"
export REPOSITORY_PUBLIC_URL=https://repository.test.invalid/vinyl-cache
export R2_ACCOUNT_ID=test R2_BUCKET=test R2_ACCESS_KEY_ID=test R2_SECRET_ACCESS_KEY=test
export PURGE_DRY_RUN=1

purged_urls() {
  [[ -s $1 ]] || return 0
  python3 - "$1" <<'PY'
import json
import sys

for line in open(sys.argv[1]):
    for url in json.loads(line)["files"]:
        print(url)
PY
}

uploaded_keys() { [[ -f $1 ]] || return 0; awk -F'\t' '$1 == "put-object" { print $2 }' "$1" | sort -u; }
stored_header() { sed -n "$2p" "$HEADERS/$1"; }
page_digests() { (cd "$STORE" && find . -name index.html -type f | sort | xargs -r md5sum | sort); }

PURGE_DRY_RUN_LOG="$PURGE/publish-1.json" MOCK_R2_LOG="$CALLS/publish-1" "$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"
# createrepo_c names metadata after its content, so a second run leaves the
# first run's files in the store; check the first purge before that happens.
(( $(wc -l <"$PURGE/publish-1.json") == 1 )) || fail "a target's replaceable set must purge in one batch"
first_purge=$(purged_urls "$PURGE/publish-1.json")
while IFS= read -r key; do
  grep -qxF "$REPOSITORY_PUBLIC_URL/${key#vinyl-cache/}" <<<"$first_purge" ||
    fail "publication did not purge $key"
done < <(cd "$STORE" && find "$METADATA_DIR" -type f | sort)
grep -qxF "$REPOSITORY_PUBLIC_URL/${CLIENT_KEY#vinyl-cache/}" <<<"$first_purge" ||
  fail "publication did not purge the client configuration"
while IFS= read -r payload; do
  [[ $(stored_header "${payload#"$STORE"/}" 2) == 'public, max-age=31536000, immutable' ]] ||
    fail "payload object is not immutably cacheable: $payload"
done < <(find "$PAYLOAD_GLOB" -type f | sort)
[[ $(stored_header "$METADATA_KEY" 2) == 'public, max-age=600' ]] ||
  fail "signed metadata is not short-lived in the cache"
[[ $(stored_header vinyl-cache/vcache-archive-keyring.asc 2) == 'public, max-age=3600' ]] ||
  fail "the public key object is not cacheable for an hour"

PURGE_DRY_RUN_LOG="$PURGE/publish-2.json" MOCK_R2_LOG="$CALLS/publish-2" "$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"

if PURGE_DRY_RUN_FAIL=1 PURGE_DRY_RUN_LOG="$PURGE/publish-3.json" MOCK_R2_LOG="$CALLS/publish-3" \
  "$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"; then
  fail "a failed cache purge must fail the publication"
fi
grep -qF "$METADATA_KEY" "$CALLS/publish-3" ||
  fail "the failed publication must still have uploaded its tree"
PURGE_DRY_RUN_LOG="$PURGE/publish-4.json" MOCK_R2_LOG="$CALLS/publish-4" "$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"
repeat_purge=$(purged_urls "$PURGE/publish-4.json")
grep -qxF "$REPOSITORY_PUBLIC_URL/vcache-archive-keyring.asc" <<<"$repeat_purge" ||
  fail "a rerun must re-record the immutable public key URL"
while IFS= read -r payload; do
  grep -qxF "$REPOSITORY_PUBLIC_URL/${payload#"$STORE"/vinyl-cache/}" <<<"$repeat_purge" ||
    fail "a rerun must re-record every immutable payload URL"
done < <(find "$PAYLOAD_GLOB" -type f | sort)
[[ $(stored_header vinyl-cache/vcache-archive-keyring.asc 2) == 'public, max-age=3600' ]] ||
  fail "the verified-identical path must not rewrite stored metadata"

VERIFY_HOME="$TMP/verify"
mkdir -m 700 "$VERIFY_HOME"
gpg --homedir "$VERIFY_HOME" --batch --import "$REPO/keys/vcache-archive-keyring.asc" >/dev/null
chmod 755 "$TMP" "$REPO" "$STORE"
chmod -R a+rX "$REPO/keys" "$STORE"

if [[ $FORMAT == deb ]]; then
  PREFIX="$STORE/$PREFIX_KEY"
  gpg --homedir "$VERIFY_HOME" --batch --verify "$PREFIX/dists/stable/Release.gpg" "$PREFIX/dists/stable/Release"
  gpg --homedir "$VERIFY_HOME" --batch --verify "$PREFIX/dists/stable/InRelease"
  SOURCE_FILE="$TMP/test.sources"
  cat >"$SOURCE_FILE" <<EOF
Types: deb
URIs: file://$PREFIX
Suites: stable
Components: main
Architectures: $DEB_ARCH
Signed-By: $REPO/keys/vcache-archive-keyring.asc
EOF
  chmod 777 "$TMP"
  apt-get -o Dir::Etc::sourcelist="$SOURCE_FILE" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 update >/dev/null
  (
    cd "$TMP"
    apt-get -o Dir::Etc::sourcelist="$SOURCE_FILE" -o Dir::Etc::sourceparts=- download vinyl-cache vinyl-vmod-example >/dev/null
  )
  actual=$(for field in Package Version Architecture; do dpkg-deb -f "$TMP/vinyl-cache_42.3.7-1_$DEB_ARCH.deb" "$field"; done)
  [[ $actual == $'vinyl-cache\n42.3.7-1\n'"$DEB_ARCH" ]]
  actual=$(for field in Package Version Architecture; do dpkg-deb -f "$TMP/vinyl-vmod-example_1.7-1~vinyl42.3.7.1_$DEB_ARCH.deb" "$field"; done)
  [[ $actual == $'vinyl-vmod-example\n1.7-1~vinyl42.3.7.1\n'"$DEB_ARCH" ]]
  apt-get -o Dir::Etc::sourcelist="$SOURCE_FILE" -o Dir::Etc::sourceparts=- -y install vinyl-cache vinyl-vmod-example >/dev/null
  [[ $(dpkg-query -W -f='${Version}\t${Architecture}' vinyl-cache) == $'42.3.7-1\t'"$DEB_ARCH" ]]
  [[ $(dpkg-query -W -f='${Version}\t${Architecture}' vinyl-vmod-example) == $'1.7-1~vinyl42.3.7.1\t'"$DEB_ARCH" ]]
else
  PREFIX="$STORE/$PREFIX_KEY"
  rpmdb="$TMP/rpmdb"
  mkdir "$rpmdb"
  rpm --dbpath "$rpmdb" --import "$REPO/keys/vcache-archive-keyring.asc"
  rpmkeys --dbpath "$rpmdb" --checksig --verbose "$PREFIX/Packages/vinyl-cache-42.3.7-1.$RPM_ARCH.rpm" | grep -Eq 'Signature.*: OK$'
  gpg --homedir "$VERIFY_HOME" --batch --verify "$PREFIX/repodata/repomd.xml.asc" "$PREFIX/repodata/repomd.xml"
  rpm --import "$REPO/keys/vcache-archive-keyring.asc"
  python3 -m http.server 18080 --bind 127.0.0.1 --directory "$STORE/vinyl-cache" >/dev/null 2>&1 &
  SERVER=$!
  sleep 1
  REPO_FILE="$TMP/test.repo"
  cat >"$REPO_FILE" <<EOF
[test]
name=Repository publisher test
baseurl=http://127.0.0.1:18080/rpm/vinyl/$RPM_TARGET
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=http://127.0.0.1:18080/vcache-archive-keyring.asc
EOF
  dnf --config "$REPO_FILE" --disablerepo='*' --enablerepo=test -y makecache >/dev/null
  dnf --config "$REPO_FILE" --disablerepo='*' --enablerepo=test -y install vinyl-cache >/dev/null
  [[ $(rpm -q --qf '%{NEVRA}' vinyl-cache) == "vinyl-cache-42.3.7-1.$RPM_ARCH" ]]
fi

PURGE_DRY_RUN_LOG="$PURGE/site-1.json" MOCK_R2_LOG="$CALLS/site-1" "$REPO/scripts/publish-site.sh"
[[ -f "$STORE/vinyl-cache/index.html" ]] || fail "the site publisher did not create the root page"
[[ -f "$STORE/$PREFIX_KEY/index.html" ]] || fail "the site publisher did not create the target page"
reserved=$(find "$STORE" -name index.html -type f -exec grep -l 'index.html</a>' {} + || true)
[[ -z $reserved ]] || fail "a generated listing shows the reserved index.html: $reserved"
if [[ $FORMAT == deb ]]; then
  grep -q 'vinyl-vmod-example' "$STORE/$PREFIX_KEY/index.html" || fail "the target page has no package table"
  grep -q '1.7-1~vinyl42.3.7.1' "$STORE/$PREFIX_KEY/index.html" || fail "the package table has no version"
else
  grep -q 'NVRA' "$STORE/$PREFIX_KEY/index.html" || fail "the target page has no NVRA table"
  grep -q "Packages/vinyl-cache-42.3.7-1.$RPM_ARCH.rpm" "$STORE/$PREFIX_KEY/index.html" ||
    fail "the NVRA table does not link its package"
fi
grep -qxF "$REPOSITORY_PUBLIC_URL/" <<<"$(purged_urls "$PURGE/site-1.json")" ||
  fail "the site publisher did not purge the directory form of the root page"
[[ $(stored_header vinyl-cache/index.html 1) == 'text/html; charset=utf-8' ]] ||
  fail "generated pages must be served as HTML"
[[ $(stored_header vinyl-cache/index.html 2) == 'public, max-age=600' ]] ||
  fail "generated pages must be short-lived in the cache"

PURGE_DRY_RUN_LOG="$PURGE/site-2.json" MOCK_R2_LOG="$CALLS/site-2" "$REPO/scripts/publish-site.sh"
[[ ! -e "$PURGE/site-2.json" ]] || fail "an unchanged site must purge nothing"
[[ -z $(uploaded_keys "$CALLS/site-2") ]] || fail "an unchanged site must upload nothing"

PURGE_DRY_RUN_LOG="$PURGE/publish-5.json" MOCK_R2_LOG="$CALLS/publish-5" "$REPO/scripts/publish-$PUBLISHER.sh" "$NEXT_STAGE"
page_digests >"$TMP/pages-before"
PURGE_DRY_RUN_LOG="$PURGE/site-3.json" MOCK_R2_LOG="$CALLS/site-3" "$REPO/scripts/publish-site.sh"
page_digests >"$TMP/pages-after"
changed=$(comm -13 "$TMP/pages-before" "$TMP/pages-after" | awk '{print $2}' | sed 's|^\./||' | sort)
[[ -n $changed ]] || fail "a new package revision must change at least one page"
grep -qxF "$PREFIX_KEY/index.html" <<<"$changed" || fail "the target page must change with a new revision"
if grep -qxF vinyl-cache/index.html <<<"$changed"; then fail "the root page must not change with a new revision"; fi
[[ $(uploaded_keys "$CALLS/site-3") == "$changed" ]] || fail "only changed pages may be uploaded"
expected_purge=$(while IFS= read -r key; do
  rel=${key#vinyl-cache/}
  printf '%s/%s\n%s/%s\n' "$REPOSITORY_PUBLIC_URL" "$rel" "$REPOSITORY_PUBLIC_URL" "${rel%index.html}"
done <<<"$changed" | sort -u)
[[ $(purged_urls "$PURGE/site-3.json" | sort -u) == "$expected_purge" ]] ||
  fail "purged URLs do not match the re-uploaded pages"

printf 'ok - %s publish round trip\n' "$FORMAT"
