# Repository operations guide

This guide is for maintainers of the Vinyl Cache package repository. End users should follow the installation instructions in the [README](../README.md).

## Commissioning

1. Review [`keys/vcache-archive-keyring.asc`](../keys/vcache-archive-keyring.asc) against the primary fingerprint below. Record the same value in the protected `production` GitHub environment as `REPOSITORY_GPG_FINGERPRINT`.
2. Store an unencrypted CI export of the matching private archive key, base64 encoded, as `REPOSITORY_GPG_PRIVATE_KEY_B64`. Keep the offline backup encrypted and retain its revocation certificate outside GitHub. Replacing the archive key is a manual trust-root migration, not routine maintenance.
3. Configure `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `REPOSITORY_PUBLIC_URL` in the protected environment. `REPOSITORY_PUBLIC_URL` is the production custom-domain URL mapped to the bucket's `vinyl-cache/` prefix. It must end in `/vinyl-cache`; for this deployment it is `https://packages.boffinate.com/vinyl-cache`. Use a dedicated R2 credential for this workflow without delete permission.
4. Configure four rules on the production custom domain in the Cloudflare dashboard. Do not advertise an `r2.dev` URL.
5. Add `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_API_TOKEN` to the protected environment. Scope the token to the production zone with the single permission Zone › Cache Purge. Publication purges only the URLs it replaced and never purges the zone.
6. Restrict the `production` environment to `main` and require a reviewer. Add the public URL and fingerprint as repository variables with the same names so the secret-free smoke job can read them.

The four rules are, in dashboard terms:

(a) Cache Rule. Expression:

~~~
(http.host eq "packages.boffinate.com" and starts_with(http.request.uri.path, "/vinyl-cache/"))
~~~

Set cache eligibility to Eligible for cache, Edge TTL to "Use cache-control header if present, use default Cloudflare caching behavior if not", and Browser TTL to Respect origin. Objects published before this rule existed carry no `Cache-Control` and fall back to Cloudflare's status-code defaults, which this mode cannot change: 120 minutes for 200, 206 and 301, and 3 minutes for 404 and 410. Legacy replaceable metadata is therefore cacheable for up to 120 minutes until its target is republished, and republishing purges those URLs, so no client is served a new index against stale files.

(b) URL Rewrite Rule with a dynamic path rewrite. Expression:

~~~
(http.host eq "packages.boffinate.com" and starts_with(http.request.uri.path, "/vinyl-cache/") and ends_with(http.request.uri.path, "/"))
~~~

Rewrite the path to:

~~~
concat(http.request.uri.path, "index.html")
~~~

(c) Redirect Rule. Expression:

~~~
(http.host eq "packages.boffinate.com" and http.request.uri.path eq "/vinyl-cache")
~~~

Static redirect to `https://packages.boffinate.com/vinyl-cache/` with status 301.

(d) Redirect Rule. Expression:

~~~
(http.host eq "packages.boffinate.com" and http.request.uri.path eq "/")
~~~

Static redirect to `https://packages.boffinate.com/vinyl-cache/` with status 301. This one is a convenience: `/` does not match rule (b), so without it the bare host returns R2's 404.

## Cut over to the cached site

Run these steps in order. Steps 1, 2 and 4 are manual.

1. Merge the code and confirm in the Cloudflare dashboard that the R2 credential has list permission. An R2 "Object Read & Write" token includes it.
2. Add `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_API_TOKEN` to the `production` environment.
3. Republish one live target, or dispatch `site.yml`, while the old cache-bypass rule is still in place. This proves purge and site generation with nothing yet cached.
4. Replace the bypass rule with rules (a) to (d) above.
5. Verify: a newly published payload answers `cache-control: public, max-age=31536000, immutable` and `cf-cache-status: HIT` on a second fetch; a legacy payload has no `cache-control` but still hits within Cloudflare's 120-minute default; `dists/stable/InRelease` answers `max-age=600`; `/vinyl-cache/` returns HTML; `/vinyl-cache` and `/` return 301; a target directory lists `dists/` and `pool/` with no `index.html` entry and shows the package table. Then publish the deferred targets.

## Regenerate the site

Dispatch `site.yml` from `main` to rebuild every page from the current bucket contents without republishing packages. It shares the publication concurrency group, so it can never snapshot a half-uploaded target. Use it after editing `README.md`, which is the source of the root page, or the page template. A run that finds nothing changed uploads nothing and purges nothing.

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

If the checked-in public key, configured fingerprint, or private signing key disagree, stop publication and investigate the trust-root configuration. A key replacement needs a documented trust-root migration and a client communication plan; it is not a routine retry. The keyring object is immutable and is never rewritten, so purge `https://packages.boffinate.com/vinyl-cache/vcache-archive-keyring.asc` by hand as part of that migration.

A failed cache purge fails the publication after its objects are uploaded, and it also fails the site step and skips smoke. That is not a repository-integrity incident. Dispatch the same `source_tag` again: a rerun re-records every URL it touches, immutable payloads included, and purges them. Until it succeeds, staleness is bounded by the object's own `Cache-Control`, which is ten minutes for replaceable metadata, or by Cloudflare's 120-minute default for any object published before the cache rule was added.

## Respond to smoke-test failures

The public-client smoke test starts a new native container for every attempt. It retries up to six times with a ten-second delay to allow bounded custom-domain or cache propagation after ordered metadata publication. `SMOKE_ATTEMPTS` accepts 1–10 and `SMOKE_RETRY_DELAY_SECONDS` accepts 0–60; change them only for a documented incident that needs a different bounded window.

A final smoke-test failure is actionable. Retain the workflow logs, check the custom-domain mapping and the `vinyl-cache/` cache rule, fix the external condition, then rerun the same source tag.

Successful smoke output proves that the installed Debian package version and architecture, or installed RPM NEVRA, exactly match the validated producer assets. Treat any mismatch as a repository-integrity incident: stop further dispatches, preserve logs and object identifiers, investigate, and only then retry.
