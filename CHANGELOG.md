# Package release notes

Changes to package availability, compatibility, and installation in the Varnish Cache and Vinyl Cache package repositories. Check the [repository browser](https://packages.boffinate.com/vinyl-cache/) for the packages and versions currently published for your target.

Dated entries describe published changes. Unreleased entries describe planned changes; a merged packaging change does not mean the packages are available yet.

## Unreleased

- **Retired: gossip.** We no longer build or track the gossip VMOD because upstream archived the project and we are not maintaining a fork. The source and existing upstream tags remain available. Gossip was already excluded from package builds, so this decision does not change the package set. It does not uninstall an existing package. [Packaging PR 5](https://github.com/boffinate/vcache-packaging/pull/5), merged 2026-10-12.
- **Updated: redis and cfg for the 9.0 engines.** Upcoming packages for Vinyl Cache 9.0.1 and Varnish Cache 9.0.4 will use redis 23.4 (upstream tag `9.0-23.4`) and cfg 21.3 (tag `9.0-21.3`). The 9.1 engine selections are unchanged. Redis replaces `redis.subnets()` with regexp-based `redis.weights()` and uses `CLUSTER SHARDS` for cluster discovery; review VCL using `redis.subnets()` and your Redis server compatibility before upgrading. Cfg isolates task state between script instances. The affected package names are `vinyl-vmod-redis`, `varnish-vmod-redis`, `vinyl-vmod-cfg`, and `varnish-vmod-cfg`. [Packaging PR 6](https://github.com/boffinate/vcache-packaging/pull/6), merged 2026-10-12. These packages have not been published by that PR.
