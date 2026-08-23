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
STORE="$TMP/object-store"
MOCK_BIN="$TMP/bin"
mkdir -p "$REPO" "$STAGE" "$STORE" "$MOCK_BIN"
cp -a "$ROOT/." "$REPO"

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
key_from_uri() { printf '%s' "${1#s3://*/}"; }
case $command in
  s3api)
    [[ $1 == head-object || $1 == put-object ]] || exit 2
    operation=$1
    shift
    key= body=
    while (($#)); do
      case $1 in
        --bucket) shift 2 ;;
        --key) key=$2; shift 2 ;;
        --body) body=$2; shift 2 ;;
        --content-type|--if-none-match) shift 2 ;;
        *) echo "unexpected AWS argument: $1" >&2; exit 2 ;;
      esac
    done
    path="$store/$key"
    if [[ $operation == head-object ]]; then
      [[ -f $path ]] && exit 0
      echo "404 Not Found" >&2
      exit 255
    fi
    if [[ -e $path ]]; then
      echo "PreconditionFailed" >&2
      exit 1
    fi
    mkdir -p "${path%/*}"
    cp "$body" "$path"
    ;;
  s3)
    [[ $1 == cp ]] || exit 2
    source=$2 destination=$3
    if [[ $source == s3://* ]]; then
      cp "$store/$(key_from_uri "$source")" "$destination"
    else
      path="$store/$(key_from_uri "$destination")"
      mkdir -p "${path%/*}"
      cp "$source" "$path"
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

if [[ $FORMAT == deb ]]; then
  DEB_ARCH=$(dpkg --print-architecture)
  case $DEB_ARCH in
    amd64|arm64) DEB_TARGET="debian-13-$DEB_ARCH" ;;
    *) echo "unsupported Debian test architecture: $DEB_ARCH" >&2; exit 2 ;;
  esac
  PACKAGE_ROOT="$TMP/package"
  mkdir -p "$PACKAGE_ROOT/DEBIAN"
  cat >"$PACKAGE_ROOT/DEBIAN/control" <<EOF
Package: vinyl-cache
Version: 42.3.7-1
Architecture: $DEB_ARCH
Maintainer: Repository test <test@example.invalid>
Section: admin
Priority: optional
Description: Repository publisher test package
EOF
  dpkg-deb --build "$PACKAGE_ROOT" "$STAGE/vinyl-cache_42.3.7-1_$DEB_ARCH.deb" >/dev/null
  TAG=vinyl-42.3.7-$DEB_TARGET
else
  RPM_ARCH=$(rpm --eval '%{_arch}')
  case $RPM_ARCH in
    x86_64) RPM_TARGET=el10-x86_64 ;;
    aarch64) RPM_TARGET=el10-aarch64 ;;
    *) echo "unsupported RPM test architecture: $RPM_ARCH" >&2; exit 2 ;;
  esac
  TOPDIR="$TMP/rpmbuild"
  mkdir -p "$TOPDIR/SPECS"
  cat >"$TOPDIR/SPECS/vinyl-cache.spec" <<EOF
Name: vinyl-cache
Version: 42.3.7
Release: 1
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
  rpmbuild --define "_topdir $TOPDIR" -bb "$TOPDIR/SPECS/vinyl-cache.spec" >/dev/null
  cp "$TOPDIR/RPMS/$RPM_ARCH/vinyl-cache-42.3.7-1.$RPM_ARCH.rpm" "$STAGE/"
  TAG=vinyl-42.3.7-$RPM_TARGET
fi

PACKAGE=$(find "$STAGE" -maxdepth 1 -type f -name "*.$FORMAT" -printf '%f\n')
printf '%s  %s\n' "$(sha256sum "$STAGE/$PACKAGE" | awk '{print $1}')" "$PACKAGE" >"$STAGE/SHA256SUMS"
printf '%s\n' "$TAG" >"$STAGE/.source-tag"
printf 'ok\n' >"$STAGE/.validated"
python3 "$REPO/tools/release.py" verify --stage "$STAGE" --routes "$REPO/routes.tsv"

export PATH="$MOCK_BIN:$PATH"
export MOCK_R2_DIR="$STORE"
export REPOSITORY_GPG_PRIVATE_KEY_B64="$PRIVATE_KEY_B64"
export REPOSITORY_GPG_FINGERPRINT="$FINGERPRINT"
export REPOSITORY_PUBLIC_URL=https://repository.test.invalid/vinyl-cache
export R2_ACCOUNT_ID=test R2_BUCKET=test R2_ACCESS_KEY_ID=test R2_SECRET_ACCESS_KEY=test
if [[ $FORMAT == deb ]]; then
  PUBLISHER=apt
else
  PUBLISHER=rpm
fi
"$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"
"$REPO/scripts/publish-$PUBLISHER.sh" "$STAGE"

VERIFY_HOME="$TMP/verify"
mkdir -m 700 "$VERIFY_HOME"
gpg --homedir "$VERIFY_HOME" --batch --import "$REPO/keys/vcache-archive-keyring.asc" >/dev/null
chmod 755 "$TMP" "$REPO" "$STORE"
chmod -R a+rX "$REPO/keys" "$STORE"

if [[ $FORMAT == deb ]]; then
  PREFIX="$STORE/vinyl-cache/apt/vinyl/$DEB_TARGET"
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
    apt-get -o Dir::Etc::sourcelist="$SOURCE_FILE" -o Dir::Etc::sourceparts=- download vinyl-cache >/dev/null
  )
  actual=$(for field in Package Version Architecture; do dpkg-deb -f "$TMP/$PACKAGE" "$field"; done)
  [[ $actual == $'vinyl-cache\n42.3.7-1\n'"$DEB_ARCH" ]]
  apt-get -o Dir::Etc::sourcelist="$SOURCE_FILE" -o Dir::Etc::sourceparts=- -y install vinyl-cache >/dev/null
  [[ $(dpkg-query -W -f='${Version}\t${Architecture}' vinyl-cache) == $'42.3.7-1\t'"$DEB_ARCH" ]]
else
  PREFIX="$STORE/vinyl-cache/rpm/vinyl/$RPM_TARGET"
  rpmdb="$TMP/rpmdb"
  mkdir "$rpmdb"
  rpm --dbpath "$rpmdb" --import "$REPO/keys/vcache-archive-keyring.asc"
  rpmkeys --dbpath "$rpmdb" --checksig --verbose "$PREFIX/Packages/$PACKAGE" | grep -Eq 'Signature.*: OK$'
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

printf 'ok - %s publish round trip\n' "$FORMAT"
