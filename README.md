# vcache-repository

This sibling repository publishes the checked, unsigned package assets from the fixed `vcache-packaging` GitHub repository as signed APT and RPM repositories on Cloudflare R2.

It is intentionally a thin distributor. It contains no source pins, catalog, package recipes or build logic. `fetch-release.sh` accepts only a source tag; the producer repository and route table are checked in.

## Commissioning

1. Replace `keys/vcache-archive-keyring.asc` with the reviewed armored public certificate and record its full primary fingerprint in the protected `production` environment as `REPOSITORY_GPG_FINGERPRINT`.
2. Store an unencrypted CI export of the matching private archive key, base64 encoded, as `REPOSITORY_GPG_PRIVATE_KEY_B64`. Keep the offline backup encrypted and retain its revocation certificate outside GitHub. Key replacement is a manual trust-root migration.
3. Configure `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `REPOSITORY_PUBLIC_URL` in the protected environment. `REPOSITORY_PUBLIC_URL` is the production custom-domain URL mapped to the bucket's `vinyl-cache/` prefix and must end in `/vinyl-cache`, for example `https://packages.example.org/vinyl-cache`. Use a dedicated R2 credential for this workflow; it must not grant delete access.
4. Configure one cache-bypass rule for the `vinyl-cache/` prefix on the production custom domain. Do not advertise `r2.dev`.
5. Restrict the `production` environment to `main` and require a reviewer. Add the public URL and fingerprint as repository variables with the same names so the secret-free smoke job can read them.

The public key object is written only when absent. Existing bytes must match the checked-in certificate and fingerprint.

## Manual publication

Dispatch `publish.yml` from `main` with a `source_tag` such as `vinyl-X.Y.Z-debian-13-amd64`. Fetch and validation happen before the protected signing job. APT uses `reprepro` and signs `Release`, `Release.gpg`, and `InRelease`; RPM payloads are signed with `rpmsign`, repository metadata with a detached OpenPGP signature, and clients require both package and repository signatures.

Install the generated `.sources` or `.repo` file from the public URL. Never use `apt-key`, `trusted=yes`, `gpgcheck=0`, or `repo_gpgcheck=0`.

For APT, verify the documented full fingerprint before saving the key to `/etc/apt/keyrings/vcache-archive-keyring.asc`, then save `apt/<family>/<target>/vcache-<family>.sources` under `/etc/apt/sources.list.d/` and run `apt-get update`.

For DNF, save the verified key under `/etc/pki/rpm-gpg/`, save `rpm/<family>/vcache-<family>.repo` under `/etc/yum.repos.d/`, and run `dnf makecache`. The published file enables both `gpgcheck` and `repo_gpgcheck`.
