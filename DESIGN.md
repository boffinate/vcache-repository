# Design

Status: normative for the v1 sibling distributor.

## Input contract

The producer repository is the checked-in constant `boffinate/vcache-packaging` in `tools/release.py`; dispatch accepts only `source_tag`. Tags have the form `<engine-id>-<target-id>`, are non-draft/non-prerelease, and contain exactly the package set plus `SHA256SUMS`.

`SHA256SUMS` uses lowercase SHA-256, two spaces, and basename-only filenames. It covers every package and not itself. Validation resolves one release, downloads by asset ID into a temporary directory, verifies the exact asset set and checksums, matches the tag to `routes.tsv`, and checks native package metadata before secrets or R2 are available. It is an integrity contract, not provenance.

## Routes and roots

`routes.tsv` is the distributor-owned target allow-list. Package files remain authoritative for family, version, revision and package identity. Every root is scoped as `vinyl-cache/<format>/<family>/<target>/`; `REPOSITORY_PUBLIC_URL` is the custom-domain URL corresponding to the `vinyl-cache/` prefix. Payload objects are immutable and indexes are replaceable current-channel state.

## Signing

The checked-in key is public. Commissioning supplies one dedicated archive private key to a protected, main-only, reviewer-gated environment. The job imports it into a mode-0700 temporary `GNUPGHOME`, requires the configured full fingerprint and signing capability, and removes the directory on exit. Keep an encrypted backup and revocation certificate outside GitHub; replacement is a manual trust-root migration.

## Publication

Build a fresh family/target tree. Upload the public key if absent, then package payloads, ordinary metadata, and signed top-level metadata last. Never overwrite or delete payload objects and never use `sync --delete`. The serialized workflow is the only writer using its dedicated R2 credential. R2 production uses a custom domain with one cache-bypass rule for the `vinyl-cache/` prefix.

The manual publisher runs in the route's native Debian, Ubuntu or AlmaLinux utility container and installs only the required format tools before invoking the scripts. Native client smoke runs in a fresh container on the same native runner; v1 does not add a long-lived build image.

APT uses `reprepro` with `SignWith`, and verifies `Release`, `Release.gpg`, and `InRelease`. RPM payloads use `rpmsign` and `rpmkeys`; `createrepo_c` metadata is accompanied by armored `repomd.xml.asc`. Generated clients require `gpgcheck=1`, `repo_gpgcheck=1`, TLS verification, and an explicit APT `Signed-By` path.

## Retry contract

Debian retries compare whole-file SHA-256 with the producer checksum. RPM retries compare NEVRA, `SHA256HEADER`, and `PAYLOADDIGEST`, then verify the existing archive-key signature and reuse exact signed bytes. A mismatch fails and requests a producer package-revision bump.
