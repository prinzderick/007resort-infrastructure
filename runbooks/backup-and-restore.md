# Runbook: backup and restore (Local node and Cloud node)

> **DRAFT** - pending architecture approval. Backup is **not** synchronization and **not** a VM snapshot
> (ADR-0013): each node has its own backups, and a copy that only lives on the machine it protects is not a backup.

## Strategy

| Layer | Local node (Windows) | Cloud node (VPS) |
| --- | --- | --- |
| Full logical backup | `mysqldump --single-transaction --routines --triggers --events --source-data=2`, gzip, verified. Task `R007 Nightly Backup`, 02:30 local | same, `/usr/local/sbin/r007-backup`, cron 01:30 UTC (= 02:30 Lagos) |
| Point-in-time (PITR) | ROW binlogs (`r007-binlog.*`, 14-day expiry); closed logs copied with each backup | same; closed binlogs archived (encrypted) with each run |
| Second copy | NAS: `\\nas.site.local\r007-backups\{full,binlog}` with SHA-256 verification | provider snapshot (extra safety only) |
| Off-site copy | optional via `rclone` (+ `age`) - **recommended**: a fire/theft/ransomware at the property must not take the only copies | **required**: `rclone` to any S3/B2/GCS/SFTP remote, encrypted with `age` |
| Config/secret backup | `shared\.env` is in the site record / password vault (never plain on the NAS) | `shared/.env` uploaded **encrypted only** (skipped if no `AGE_RECIPIENT`) |
| Retention | local 7 d, NAS 35 d, off-site 35 d daily + monthly (proposal) | local 7 d, remote 35 d |
| Script | [`scripts/windows/backup-mysql.ps1`](../scripts/windows/backup-mysql.ps1) | [`scripts/vps/backup.sh`](../scripts/vps/backup.sh) |
| Restore | [`scripts/windows/restore-mysql.ps1`](../scripts/windows/restore-mysql.ps1) | manual (below) + [`scripts/vps/restore-test.sh`](../scripts/vps/restore-test.sh) |

**Targets (proposal): RPO <= 15 min (needs binlog shipping every 15 min - not yet automated, see "Gaps"), RTO <= 4 h.**
A backup older than 26 hours is an incident (`status.ps1` flags it; on Cloud set `HEALTHCHECK_URL` for a dead-man's-switch).

**Cloud backups cover three things** (all age-encrypted, uploaded off-server): the MySQL dump + binlogs (`r007-<UTC>.sql.gz.age`), the **uploaded media**
(`r007-media-<UTC>.tar.gz.age` = the API's `shared/storage/app/public`, i.e. CMS images) and the **`.env` files** of api/site/admin + `stack.env` (`r007-env-<UTC>.tar.gz.age`, only ever uploaded encrypted).
`r007-restore-test` checks all three. Set `MEDIA_BACKUP=off` in `backup.env` only if you back the media directory up another way.

### Credentials and encryption (no secrets in scripts)

- Windows: MySQL credentials only in `C:\R007\secrets\mysql-backup.cnf` (`--defaults-extra-file`; ACL Administrators/SYSTEM).
  NAS credentials, if the NAS is not domain-integrated, in `C:\R007\secrets\nas.cred` (`user=`/`password=` lines, same ACL).
- VPS: dumps run as root over the MySQL socket (no password). rclone credentials live in root's `rclone.conf` (`rclone config`).
- **Encryption:** generate an `age` key pair on an *admin workstation* (`age-keygen`); put only the **public** key in
  `AGE_RECIPIENT` (VPS: `/etc/r007/backup.env`; Windows: `AgeRecipient` in `C:\R007\install-state.json`). The private key
  lives in the password vault + a sealed copy with the owner, **never on the servers**. Without it off-site backups are unreadable - test that (below).

### One-time setup - Cloud off-site copy

```bash
sudo rclone config                       # create remote, e.g. "r007-offsite" (S3/B2/GCS/SFTP...); prefer a bucket with versioning / object lock
sudo cp /etc/r007/backup.env.example /etc/r007/backup.env && sudo chmod 600 /etc/r007/backup.env
sudoedit /etc/r007/backup.env            # RCLONE_REMOTE=r007-offsite:007resort-cloud-backups  AGE_RECIPIENT=age1...
sudo r007-backup --dry-run && sudo r007-backup      # then confirm the object exists off-server
```

## Nightly job - what the scripts guarantee

1. Dump to a temp file; **fail** on non-zero exit, on a missing `-- Dump completed` trailer or on a corrupt gzip.
2. Write a `.sha256`; copy to the NAS / remote and **verify** the copy (checksum / `rclone check`).
3. Rotate binlogs and archive the closed ones.
4. Prune by retention only after everything above succeeded.
5. Failure -> non-zero exit, Windows Application event (source `R007-Backup`, id 7000) / cron mail / healthcheck `/fail`.

## Restore - Local node

**Never restore over the live database without a decision from the IT lead** ([incident response](incident-response.md)).

```powershell
# a) prove a backup is good, any time (this is the quarterly test): restores to a scratch DB, checks, drops it
C:\R007\scripts\restore-mysql.ps1 -BackupFile D:\R007Backups\full\r007-<UTC>.sql.gz -VerifyOnly

# b) inspect data in a side database (never the live one)
C:\R007\scripts\restore-mysql.ps1 -BackupFile <file> -TargetDatabase r007_inspect

# c) disaster recovery: stops R007-* services, safety-dumps the current DB, recreates the live DB, restarts
C:\R007\scripts\restore-mysql.ps1 -BackupFile <file> -Live -ConfirmDatabaseName r007
```

### Point-in-time recovery (bad change at a known time)

1. Restore the newest full backup from **before** the bad event (`-Live`, but pass `-DryRun` first). Services are running again at the end -
   stop them again for the replay: `Stop-Service R007-Queue,R007-Sync,R007-Reverb; iisreset /stop`.
2. Read the binlog position from the dump header: `gzip -dc` (or 7-Zip) the file and look for `-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE=..., SOURCE_LOG_POS=...`.
3. Replay up to just before the event (times are **UTC**):
   ```powershell
   & 'C:\R007\tools\mysql\bin\mysqlbinlog.exe' --start-position=<pos> --stop-datetime="YYYY-MM-DD HH:MM:SS" `
       D:\R007Backups\binlog\r007-binlog.000012 D:\R007Backups\binlog\r007-binlog.000013 |
     & 'C:\R007\tools\mysql\bin\mysql.exe' --defaults-extra-file=C:\R007\secrets\mysql-admin.cnf
   ```
   (start with the binlog named in the header; include every later one in order.)
4. Validate with the finance lead (day's sales per operating point, stock, open tickets/bookings) before reopening.
5. **Sync after a restore:** the Local outbox/inbox state is part of the database, so a restored DB replays from its own
   position. Check `status.ps1` and the Cloud site-health page; events the Cloud already applied are ignored by `event_id`. Never edit sync
   tables by hand; if the Cloud is *ahead* of the restored Local (Local lost recent events) raise it with the API team before opening sales.

## Restore - Cloud node

```bash
# 1. get the newest dump (off-server) and decrypt with the age private key from the vault (on your workstation or temporarily on the server)
rclone copy r007-offsite:007resort-cloud-backups/daily/ ./restore/ --include 'r007-2*.sql.gz.age'
age -d -i ~/r007-age-key.txt -o dump.sql.gz r007-<UTC>.sql.gz.age

# 2. (rebuilding a lost VPS: bootstrap.sh + provision-stack.sh first; restore the .env files (api/site/admin) + stack.env from r007-env-<UTC>.tar.gz.age; unpack the
#     media archive: tar -xzf r007-media-<UTC>.tar.gz -C /var/www/r007/api/shared/storage/app/public ; then redeploy the three apps)
r007-deploy status ; sudo supervisorctl stop 'r007:*'

# 3. load (dump is made with --databases, so it recreates the schema and USEs it)
gzip -dc dump.sql.gz | sudo mysql

# 4. PITR: replay archived binlogs as on Local, with mysqlbinlog ... | sudo mysql
sudo supervisorctl start 'r007:*' ; curl -fsS http://127.0.0.1:8088/up
```

Then re-check sync with the property (the site should return to ONLINE; the outbox re-drives anything unacknowledged).

## Automated restore test (Cloud, monthly cron) and evidence

`r007-restore-test` restores the newest local dump (`--from-remote` uses the off-server copy, needs `--age-identity FILE` for `.age`)
into a throwaway database, checks the table count and Laravel `migrations` table, drops it, and appends one JSON line
(result, seconds, backup age) to `/var/log/r007/restore-test.log`. A failing result is an incident.

## Quarterly restore-test checklist (both nodes, IT lead + one witness)

Record results in the site record. **A failed test is a SEV2 incident.**

- [ ] Date/time, tester, node (Local / Cloud), backup file used (name, size, timestamp, where it came from: local / NAS / off-site)
- [ ] For the Local node **use the NAS copy** and, once a year, the **off-site** copy (proves the chain end to end)
- [ ] Checksum verified (`.sha256`); decryption with the vault key worked (off-site)
- [ ] `restore-mysql.ps1 -VerifyOnly` (Local) / `r007-restore-test --from-remote --age-identity ...` (Cloud) passed
- [ ] Duration recorded = **RTO evidence** (target <= 4 h for a full disaster restore); backup age = **RPO evidence**
- [ ] Row counts sanity-checked against production for key tables (orders, payments, bookings, audit_log, sync outbox) - within the expected window
- [ ] Once a year: full rehearsal - restore to a spare machine, start the app against it, log in, view yesterday's sales
- [ ] PITR replay rehearsed to a chosen minute (half-yearly)
- [ ] Off-site retention/versioning and the `age` key custody confirmed (two people can find the key)
- [ ] Issues, fixes and follow-ups filed; runbook updated

## Gaps (tracked)

- 15-minute binlog shipping (RPO target) is not scheduled yet; today binlogs ship with each nightly run (RPO = up to 24 h unless the disk survives).
  Add a 15-minute task/cron that runs the binlog part only.
- Windows off-site encryption uses `age.exe`/`rclone.exe` from PATH (not installed by `install.ps1`).
- Backup monitoring is local (`status.ps1`, event log); central alerting is a follow-up.
