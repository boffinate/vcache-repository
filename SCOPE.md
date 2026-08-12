# Scope

This repository is the thin distributor for signed current APT and RPM roots produced from completed releases of the fixed `vcache-packaging` repository.

In scope: strict release fetching and checksum validation, native package metadata checks, archive signing, family/target repository generation, immutable payload retries, ordered R2 uploads, public client configuration, and clean native-client smoke tests.

Out of scope: source acquisition, catalogs, compatibility matrices, package recipes, builds, source archives, cumulative history, snapshots, updateinfo/comps/modules, custom servers, workers, provenance attestations, publication ledgers, automated key rollover, and deletion or synchronization of R2 objects.

The producer remains authoritative for package identity and build quality. This repository never consumes raw Actions artifacts and never imports producer catalog or build logic.
