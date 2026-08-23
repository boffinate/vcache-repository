# Vinyl Cache package repository

This repository provides signed Debian and RPM packages for Vinyl Cache 9.0.1. Packages are available now for:

- Debian 13 on amd64 and arm64
- Ubuntu 26.04 on amd64 and arm64
- Enterprise Linux 10 on x86_64 and aarch64

Browse the published repositories, including the current package list for each target, at `https://packages.boffinate.com/vinyl-cache/`.

Packages are served from `https://packages.boffinate.com/vinyl-cache`. The setup steps below install the repository's public signing key, check its fingerprint, and configure your package manager to verify both packages and repository metadata.

The archive-key fingerprint is:

~~~
AED8146A22F2973E48AE6A1118361320BD4BACCD
~~~

## Debian 13 and Ubuntu 26.04

Choose the target that matches your distribution and architecture: `debian-13-amd64`, `debian-13-arm64`, `ubuntu-26.04-amd64`, or `ubuntu-26.04-arm64`. Set `target` to that value, then run:

~~~sh
url=https://packages.boffinate.com/vinyl-cache
target=debian-13-amd64
fingerprint=AED8146A22F2973E48AE6A1118361320BD4BACCD

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsS "$url/vcache-archive-keyring.asc" -o /tmp/vcache-archive-keyring.asc
test "$(gpg --show-keys --with-colons /tmp/vcache-archive-keyring.asc | awk -F: '$1 == "fpr" {print $10; exit}')" = "$fingerprint"
sudo install -m 0644 /tmp/vcache-archive-keyring.asc /etc/apt/keyrings/vcache-archive-keyring.asc
sudo curl -fsS "$url/apt/vinyl/$target/vcache-vinyl.sources" -o /etc/apt/sources.list.d/vcache.sources
sudo apt-get update
~~~

Install Vinyl Cache:

~~~sh
sudo apt-get install -y vinyl-cache
~~~

The development package is `vinyl-cache-dev`. Current VMOD packages are `vinyl-vmod-cachetag`, `vinyl-vmod-dict`, `vinyl-vmod-pesi`, `vinyl-vmod-remoteip`, and `vinyl-vmod-tbf`:

~~~sh
sudo apt-get install -y vinyl-cache-dev vinyl-vmod-cachetag
apt-cache search '^vinyl-vmod-'
~~~

Install any VMOD you need by name. VMOD packages depend on the matching Vinyl Cache package version, so let APT upgrade them together.

## Enterprise Linux 10

The RPM repository is available for x86_64 and aarch64. Its configuration uses your system's architecture automatically.

~~~sh
url=https://packages.boffinate.com/vinyl-cache
fingerprint=AED8146A22F2973E48AE6A1118361320BD4BACCD

sudo dnf install -y ca-certificates curl-minimal gnupg2
curl -fsS "$url/vcache-archive-keyring.asc" -o /tmp/vcache-archive-keyring.asc
test "$(gpg --show-keys --with-colons /tmp/vcache-archive-keyring.asc | awk -F: '$1 == "fpr" {print $10; exit}')" = "$fingerprint"
sudo install -m 0644 /tmp/vcache-archive-keyring.asc /etc/pki/rpm-gpg/vcache-archive-keyring.asc
sudo curl -fsS "$url/rpm/vinyl/vcache-vinyl.repo" -o /etc/yum.repos.d/vcache.repo
grep -qx 'gpgcheck=1' /etc/yum.repos.d/vcache.repo
grep -qx 'repo_gpgcheck=1' /etc/yum.repos.d/vcache.repo
sudo dnf install -y epel-release
sudo dnf makecache
~~~

EPEL is required because the Vinyl Cache RPMs use `jemalloc` and `libunwind` from EPEL. Install `epel-release` in its own transaction before refreshing metadata, as shown above.

Install Vinyl Cache:

~~~sh
sudo dnf install -y vinyl-cache
~~~

The development package is `vinyl-cache-devel`. Current VMOD packages are `vinyl-vmod-cachetag`, `vinyl-vmod-dict`, `vinyl-vmod-pesi`, `vinyl-vmod-remoteip`, and `vinyl-vmod-tbf`:

~~~sh
sudo dnf install -y vinyl-cache-devel vinyl-vmod-cachetag
dnf search vinyl-vmod
~~~

## Updates and removal

Use your normal package-manager upgrade command to receive signed updates:

~~~sh
sudo apt-get update && sudo apt-get upgrade
sudo dnf upgrade
~~~

To stop using this repository without removing installed packages, remove its configuration and key, then refresh metadata:

~~~sh
sudo rm /etc/apt/sources.list.d/vcache.sources /etc/apt/keyrings/vcache-archive-keyring.asc
sudo apt-get update

sudo rm /etc/yum.repos.d/vcache.repo /etc/pki/rpm-gpg/vcache-archive-keyring.asc
sudo dnf makecache
~~~

Remove Vinyl Cache or a VMOD separately with its exact package name if you no longer need it.

<!-- BEGIN_EXCLUDE -->
## Maintainers

Repository commissioning, publication, and recovery procedures are in [the maintainer guide](docs/20260823_1348_guide_repository-operations.md). Those instructions are for people operating the signing key, GitHub environment, and Cloudflare R2 publication workflow.
<!-- END_EXCLUDE -->
