# vcache-repository

This sibling repository publishes the checked, unsigned package assets from the fixed `vcache-packaging` GitHub repository as signed APT and RPM repositories on Cloudflare R2.

It is intentionally a thin distributor. It contains no source pins, catalog, package recipes or build logic. `fetch-release.sh` accepts only a source tag; the producer repository and route table are checked in.

## Commissioning

1. Replace `keys/vcache-archive-keyring.asc` with the reviewed armored public certificate, replace `COMMISSIONING_REQUIRED` below with its full primary fingerprint, and record the same value in the protected `production` environment as `REPOSITORY_GPG_FINGERPRINT`.
2. Store an unencrypted CI export of the matching private archive key, base64 encoded, as `REPOSITORY_GPG_PRIVATE_KEY_B64`. Keep the offline backup encrypted and retain its revocation certificate outside GitHub. Key replacement is a manual trust-root migration.
3. Configure `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `REPOSITORY_PUBLIC_URL` in the protected environment. `REPOSITORY_PUBLIC_URL` is the production custom-domain URL mapped to the bucket's `vinyl-cache/` prefix and must end in `/vinyl-cache`, for example `https://packages.example.org/vinyl-cache`. Use a dedicated R2 credential for this workflow; it must not grant delete access.
4. Configure one cache-bypass rule for the `vinyl-cache/` prefix on the production custom domain. Do not advertise `r2.dev`.
5. Restrict the `production` environment to `main` and require a reviewer. Add the public URL and fingerprint as repository variables with the same names so the secret-free smoke job can read them.

The public key object is written only when absent. Existing bytes must match the checked-in certificate and fingerprint.

## Manual publication

Dispatch `publish.yml` from `main` with a `source_tag` such as `vinyl-X.Y.Z-debian-13-amd64`. Fetch and validation happen before the protected signing job. APT uses `reprepro` and signs `Release`, `Release.gpg`, and `InRelease`; RPM payloads are signed with `rpmsign`, repository metadata with a detached OpenPGP signature, and clients require both package and repository signatures.

Expected archive-key fingerprint: `COMMISSIONING_REQUIRED`

Install the generated `.sources` or `.repo` file from the public URL. Never use `apt-key`, `trusted=yes`, `gpgcheck=0`, or `repo_gpgcheck=0`.

For APT, set `url`, `family`, `target`, and `fingerprint`, then install the key and generated deb822 source:

```sh
url=https://packages.example.org/vinyl-cache
family=vinyl
target=debian-13-amd64
fingerprint=COMMISSIONING_REQUIRED
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsS "$url/vcache-archive-keyring.asc" -o /tmp/vcache-key.asc
test "$(gpg --show-keys --with-colons /tmp/vcache-key.asc | awk -F: '$1 == "fpr" {print $10; exit}')" = "$fingerprint"
sudo install -m 0644 /tmp/vcache-key.asc /etc/apt/keyrings/vcache-archive-keyring.asc
sudo curl -fsS "$url/apt/$family/$target/vcache-$family.sources" -o /etc/apt/sources.list.d/vcache.sources
sudo apt-get update
```

The generated source is:

```text
Types: deb
URIs: https://packages.example.org/vinyl-cache/apt/vinyl/debian-13-amd64
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/vcache-archive-keyring.asc
```

For DNF, use the same `url`, `family`, and `fingerprint`, then install the key and generated repository file:

```sh
url=https://packages.example.org/vinyl-cache
family=vinyl
fingerprint=COMMISSIONING_REQUIRED
sudo dnf install -y ca-certificates curl-minimal gnupg2
curl -fsS "$url/vcache-archive-keyring.asc" -o /tmp/vcache-key.asc
test "$(gpg --show-keys --with-colons /tmp/vcache-key.asc | awk -F: '$1 == "fpr" {print $10; exit}')" = "$fingerprint"
sudo install -m 0644 /tmp/vcache-key.asc /etc/pki/rpm-gpg/vcache-archive-keyring.asc
sudo curl -fsS "$url/rpm/$family/vcache-$family.repo" -o /etc/yum.repos.d/vcache.repo
sudo dnf makecache
```

The published RPM file enables both `gpgcheck` and `repo_gpgcheck`.

## Recovery and operations

The publisher is safe to dispatch again with the same `source_tag`. A failed job may have uploaded immutable package payloads, but a retry verifies and reuses only byte-identical Debian payloads or RPMs with the same NEVRA, header digest, payload digest, and archive-key signature. It then rebuilds and republishes the mutable repository metadata. Do not delete or manually replace objects to recover a failed publication.

If a retry reports an immutable package collision, do not alter the repository object. Correct the producer input and publish a new positive package revision; use the new producer release tag for the next dispatch. If the checked-in public key, configured fingerprint, or private signing key disagree, stop publication and investigate the trust-root configuration. Replacing an archive key requires the documented manual trust-root migration, including a client communication plan; it is not a routine retry.

The public-client smoke test starts a new native container for every attempt and retries up to six times with a ten-second delay. This only accommodates bounded custom-domain or cache propagation after ordered metadata publication. Configure `SMOKE_ATTEMPTS` (1–10) and `SMOKE_RETRY_DELAY_SECONDS` (0–60) only when a documented incident needs a different bounded window. A final failure is actionable: retain the workflow logs, confirm the custom-domain mapping and `vinyl-cache/` cache-bypass rule, and rerun the same source tag after the external condition is fixed.

Successful smoke output proves the installed Debian package version and architecture, or installed RPM NEVRA, exactly match the validated producer artifacts. Treat any mismatch as a repository-integrity incident: stop further dispatches, preserve logs and object identifiers, and investigate before retrying.
