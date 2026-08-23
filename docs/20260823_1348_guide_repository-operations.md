# Repository operations guide

This guide is for maintainers of the Vinyl Cache package repository. End users should follow the installation instructions in the [README](../README.md).

## Commissioning

1. Review [`keys/vcache-archive-keyring.asc`](../keys/vcache-archive-keyring.asc) against the primary fingerprint below. Record the same value in the protected `production` GitHub environment as `REPOSITORY_GPG_FINGERPRINT`.
2. Store an unencrypted CI export of the matching private archive key, base64 encoded, as `REPOSITORY_GPG_PRIVATE_KEY_B64`. Keep the offline backup encrypted and retain its revocation certificate outside GitHub. Replacing the archive key is a manual trust-root migration, not routine maintenance.
3. Configure `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `REPOSITORY_PUBLIC_URL` in the protected environment. `REPOSITORY_PUBLIC_URL` is the production custom-domain URL mapped to the bucket's `vinyl-cache/` prefix. It must end in `/vinyl-cache`; for this deployment it is `https://packages.boffinate.com/vinyl-cache`. Use a dedicated R2 credential for this workflow without delete permission.
4. Configure one cache-bypass rule for the `vinyl-cache/` prefix on the production custom domain. Do not advertise an `r2.dev` URL.
5. Restrict the `production` environment to `main` and require a reviewer. Add the public URL and fingerprint as repository variables with the same names so the secret-free smoke job can read them.

Expected archive-key fingerprint:

~~~
AED8146A22F2973E48AE6A1118361320BD4BACCD
~~~

The publisher writes the public-key object only when it is absent. If it already exists, its bytes must match the checked-in certificate and this fingerprint.

## Publish a release

Dispatch `publish.yml` from `main` with a `source_tag`, such as `vinyl-9.0.1-debian-13-amd64`. The workflow fetches and validates assets from the fixed `boffinate/vcache-packaging` producer repository before the protected signing job starts.

Supported target suffixes are:

- `debian-13-amd64`
- `debian-13-arm64`
- `ubuntu-26.04-amd64`
- `ubuntu-26.04-arm64`
- `el10-x86_64`
- `el10-aarch64`

For APT, the workflow uses `reprepro` to sign `Release`, `Release.gpg`, and `InRelease`. For RPM, it signs package payloads with `rpmsign` and repository metadata with a detached OpenPGP signature. Published RPM configuration requires both `gpgcheck=1` and `repo_gpgcheck=1`.

## Recover from a failed publication

It is safe to dispatch the workflow again with the same `source_tag`. A failed job may have uploaded immutable package payloads. A retry checks and reuses only byte-identical Debian payloads, or RPMs with the same NEVRA, header digest, payload digest, and archive-key signature. It rebuilds and republishes the mutable repository metadata.

Do not delete or manually replace objects to recover from a failed publication. If a retry reports an immutable package collision, leave the repository object in place. Correct the producer input, publish a new positive package revision, and dispatch using the new producer release tag.

If the checked-in public key, configured fingerprint, or private signing key disagree, stop publication and investigate the trust-root configuration. A key replacement needs a documented trust-root migration and a client communication plan; it is not a routine retry.

## Respond to smoke-test failures

The public-client smoke test starts a new native container for every attempt. It retries up to six times with a ten-second delay to allow bounded custom-domain or cache propagation after ordered metadata publication. `SMOKE_ATTEMPTS` accepts 1–10 and `SMOKE_RETRY_DELAY_SECONDS` accepts 0–60; change them only for a documented incident that needs a different bounded window.

A final smoke-test failure is actionable. Retain the workflow logs, check the custom-domain mapping and the `vinyl-cache/` cache-bypass rule, fix the external condition, then rerun the same source tag.

Successful smoke output proves that the installed Debian package version and architecture, or installed RPM NEVRA, exactly match the validated producer assets. Treat any mismatch as a repository-integrity incident: stop further dispatches, preserve logs and object identifiers, investigate, and only then retry.
