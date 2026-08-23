# Deferred rollout handoff

## Status

The public package repositories currently serve Vinyl Cache 9.0.1 for Debian 13 amd64, Debian 13 arm64, and Enterprise Linux 10 x86_64 at `https://packages.boffinate.com/vinyl-cache`. Their producer release assets, signed repository metadata, and native public-client installation smoke tests have passed.

The Ubuntu 26.04 amd64 and arm64 routes, and the Enterprise Linux 10 aarch64 route, are configured but deliberately not published. Their attempted runs `32640789554`, `32640791739`, and `32640794088` were cancelled before publication. No publication run is queued or running. `publish.yml` runs only when dispatched by hand; it has no schedule. Its single concurrency group retains one running and one pending workflow run, so start the remaining targets one at a time.

## Commissioning chronology

- The signed repository publisher, native round-trip harness, retrying public smokes, and GitHub verification workflow were added in `b3fb620`, `28786b9`, and `0301daf`. The archive key was commissioned in `bc3e9d8`; its public fingerprint is recorded in the README and operations guide.
- GitHub's protected `production` environment was configured for `main` with a required reviewer. The public URL and archive-key fingerprint are available to the secret-free smoke job, while R2 and signing material are environment secrets.
- Cloudflare R2 was commissioned with the `vinyl-cache/` object prefix behind `https://packages.boffinate.com/vinyl-cache`; a cache-bypass rule for that prefix is required by the publication design. The public `r2.dev` endpoint is not advertised.
- The producer workflow initially failed because extracted GitHub release assets retained foreign ownership and Git rejected the packaging checkout as unsafe. The producer now sets an exact `safe.directory` for that checkout. Its first pilot completed successfully after that fix.
- The first pilot release manifests then failed the repository fetch seam because GitHub normalised `~` in VMOD asset filenames to `.` while the uploaded `SHA256SUMS` retained `~`. The producer now stages the GitHub-normalised filenames before generating checksums. The corrected pilot run `32633417512` completed successfully.
- The repository fetch seam was re-run in a native Ubuntu container against the corrected GitHub releases and accepted both pilot handoffs. Repository CI run `32633145963` completed successfully, including its Debian and RPM publisher round trips. An earlier verification run, `32633057050`, also passed.
- An attempted producer rollout for the four remaining targets, run `32633182536`, was cancelled before release publication when the filename/checksum mismatch was found. It created no additional releases or tags.
- The release workflow found that RPM metadata-key import needs `dnf -y makecache` for the separate repository metadata key. The smoke harness was corrected without weakening `gpgcheck` or `repo_gpgcheck`.
- An R2 secret access key was printed in diagnostic output during commissioning. Treating it as exposed, the R2 credential pair was rotated, the replacement values were stored in the maintainer Keychain, and the old credential was revoked. No secret values are recorded in this repository or this report.

## Relevant commits and evidence

Repository commits already on `main`:

- `b3fb620` — end-to-end signed-publication verification.
- `28786b9` — publication recovery procedures.
- `bc3e9d8` — commissioned archive key.
- `0301daf` — publication hardening and smoke retries.
- `a5e8d52` — separate EPEL transaction before RPM client metadata refresh.
- `9007f8b`, `3ca8797`, and `713cbf2` — publisher portability and exact APT package identity checks.
- `c275f27` — initial user installation guide.

Successful GitHub workflow evidence:

- `32633057050` — repository verification workflow passed.
- `32633145963` — repository verification workflow passed, including native Debian and RPM round trips.
- `32633417512` — corrected producer pilot completed successfully.
- `32633746688` — producer release workflow published and verified all four non-pilot package cohorts.
- `32636825221` — repository CI passed after the EPEL bootstrap fix.
- `32639357431`, `32639920177`, and `32640362048` — repository CI passed after the Debian AWS CLI and APT byte-identity fixes.
- `32640766570` — repository CI passed after the user and maintainer documentation split.
- `32639463881` — Enterprise Linux 10 x86_64 publication and native public smoke passed.
- `32640427405` — Debian 13 amd64 publication and native public smoke passed.
- `32640611699` — deliberate Debian 13 amd64 rerun passed, proving production idempotency.
- `32640786960` — Debian 13 arm64 publication and native public smoke passed.

## Finish the deferred rollout

Before dispatching, confirm that the rotated R2 credential pair is installed in the protected `production` environment under `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, that the old pair is revoked, and that `R2_ACCOUNT_ID`, `R2_BUCKET`, `REPOSITORY_PUBLIC_URL`, `REPOSITORY_GPG_PRIVATE_KEY_B64`, and `REPOSITORY_GPG_FINGERPRINT` remain configured. Confirm the custom-domain mapping and cache-bypass rule are still present.

For each target below, dispatch **Publish signed repositories** from `main` manually with the exact `source_tag`, wait for the protected environment approval, then wait for the `fetch`, `publish`, and `smoke` jobs to succeed before starting the next target:

1. `vinyl-9.0.1-ubuntu-26.04-amd64`
2. `vinyl-9.0.1-ubuntu-26.04-arm64`
3. `vinyl-9.0.1-el10-aarch64`

For every successful run, open its smoke-job log and confirm it installed the expected package version and architecture/NEVRA from `packages.boffinate.com`. Then use the README commands from a fresh native client for an independent user-facing check. Production idempotency is already proved by Debian 13 amd64 run `32640611699` and the successful Enterprise Linux 10 x86_64 retry `32639463881`. Repeating a newly published deferred target is optional; if desired, do it only after that target's first successful smoke.

If a run fails after publication begins, do not delete or manually replace repository objects. Preserve the workflow logs and rerun the same tag after correcting the external condition. Follow the recovery procedure in the repository operations guide.

## Optional hardening still outstanding

- Add branch protection for `main` if it is not already enforced outside this repository's current settings.
- Retain the encrypted archive-key backup and revocation certificate in an independent backup location, with the backup passphrase in a password manager or synced Keychain.
- Keep the Cloudflare cache-bypass rule under review as repository paths expand; the current rule must continue to cover `vinyl-cache/`.
