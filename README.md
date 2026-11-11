# db-migration

An in-place upgrade of a single-node MongoDB replica set on Ubuntu 22.04 from **7.0.x → 8.0.34 → 8.3.4**. It then installs **mongot 1.78.0** (MongoDB Search in Community) so that `$vectorSearch` works for the company-documents AI.

| File | Purpose |
|---|---|
| `scripts/migrate-mongodb.sh` | Standalone migration script. Its only input is the MongoDB URI. |
| `.github/workflows/mongodb-migration-test.yml` | End-to-end test on an Ubuntu 22.04 runner. |
| `ci/setup-source-mongodb.sh` | Sets up a prod-like 7.0 server: apt install, systemd, replica set `rs0`, keyfile, authorization, root user. |
| `ci/seed.js`, `ci/query.js`, `ci/verify-after.js` | Seed data, the before/after queries, and the post-migration assertions, including a real `$vectorSearch`. |

## What CI proves on every push

1. A MongoDB 7.0 server like production: a replica set with keyfile auth, password login enforced, and a wrong password rejected.
2. Seed data in the `workmentor` database (organizations, users, attendances, document chunks with embeddings) and a second database.
3. The migration script runs non-interactively with `STRICT_COUNTS=1`.
4. After the migration the workflow checks:
   - version 8.3.4 and FCV 8.3
   - the replica set is PRIMARY
   - every count and the unique index are intact
   - authentication is still enforced
   - mongod.conf is valid YAML, with the existing `setParameter` kept
   - packages are held
   - a vector index on data written by 7.0 becomes queryable, and `$vectorSearch` returns the right hit with the organization filter respected
5. The backup archive's checksum matches, and restoring it into another database gives identical counts.
6. Re-running the script is safe: it detects the finished state and only verifies.

Logs are uploaded as the `migration-logs` artifact. The backup archive itself is not uploaded.

## Running it on production

The script must be run **on the database host**, as root. The URI must point at the local mongod with a user that has the `root` role.

Recommended order on the production server:

```bash
# 1. Rehearse without changing anything (connection, auth, replica set, keyfile,
#    disk, ports, package downloads, before report):
sudo CHECK_ONLY=1 bash migrate-mongodb.sh

# 2. Take an EBS/disk snapshot, then stop the app writers (pm2 stop ...).

# 3. Run the migration (prompts for the URI with hidden input, then asks you to type MIGRATE):
sudo MONGOT_MEMORY_MAX=2G bash migrate-mongodb.sh

# 4. Start the app again and check it.
```

`CHECK_ONLY=1` does not touch MongoDB. The only thing it may install is `python3-yaml`, if it is missing.

Before you run it:

- **Disk:** the root disk is at 89% (8.8 GB free). The script refuses to start unless free space is larger than the uncompressed data size plus 1 GiB. If the backup should go to another disk, use `BACKUP_ROOT=/mnt/other sudo -E bash migrate-mongodb.sh`.
- **Downtime:** mongod restarts 3 times (8.0, 8.3, then search parameters). Stop the app writers first (`pm2 stop ...`) so the backup is consistent and the count comparison is exact.
- **Memory:** mongot is a JVM process and keeps the vector index in memory. The server already uses 1.4 GB of swap. `MONGOT_MEMORY_MAX=2G` caps the service through systemd, and the JVM sizes its heap from that cap. Raise the cap if the index grows.
- **Ports:** mongot uses 27028 (gRPC), 27029 (health) and 9946 (metrics), all on localhost. The health port is not the documented 8080 because nginx often listens there behind Varnish. The script stops if any of these ports is already taken. Override them with `MONGOT_*_PORT`.
- **Backup verification:** the script checks the dump log against the live collections. It also restores the whole archive into a temporary mongod on a local port and compares every collection's document and index counts. That restore test needs about (data + indexes + 1 GiB) of free disk. With the default `VERIFY_RESTORE=auto` it is skipped with a warning when space is short; `always` makes it mandatory and `never` turns it off.
- Take an EBS/disk snapshot as well. The script's `mongodump` is a logical backup; a snapshot is the fastest way back.

What the script does: pre-flight checks → before report → verified `mongodump --oplog` backup (plus copies of the config, keyfile and binaries) → upgrade to 8.0 → FCV 8.0 → upgrade to 8.3 → FCV 8.3 → mongot as a systemd service with a `searchCoordinator` user → after report → count comparison.

If a binary upgrade fails before the FCV is raised, the previous binaries are restored automatically. Once the FCV is raised there is no in-place downgrade: recovery means restoring the backup (see `RESTORE.txt` in the run directory). The script is resumable, so after fixing a failure you can run it again.

Everything for a run is written to `/var/backups/mongodb-migration/<timestamp>/`, readable by root only.
