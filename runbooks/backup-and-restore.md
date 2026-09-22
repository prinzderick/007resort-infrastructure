# Runbook: backup and restore (MySQL)

> **DRAFT** - pending architecture approval.

## Strategy

| Layer | What | When | Where |
| --- | --- | --- | --- |
| Full logical backup | `mysqldump --single-transaction` of `otueke` (routines, triggers, events) | Nightly (e.g. 02:30 local) | `D:\OtuekeBackups\full` on server |
| Binary logs | ROW-format binlogs (enables point-in-time recovery) | Continuous; copied every 15 min | `D:\OtuekeBackups\binlog` |
| NAS copy | Full + binlogs | After each job | Site NAS (SERVER VLAN) |
| Offsite / cloud copy | Encrypted full + binlogs | Nightly (outbound HTTPS) | Cloud object storage (immutable/versioned bucket) |

- **Encryption:** every file leaving the server is encrypted (e.g. AES-256 with a key held in
  the secret store, or the storage client's client-side encryption). Keys are never stored
  next to the backups.
- **Credentials:** the backup job reads MySQL credentials from a protected option file
  (`C:\Otueke\secrets\mysql-backup.cnf`, ACL: backup service account + Administrators only).
  Never pass passwords on the command line.
- **Retention (proposal):** local 7 days; NAS 35 days; offsite 35 daily + 12 monthly.
  Binlogs retained at least as long as the oldest full backup kept locally
  (`binlog_expire_logs_seconds` = 14 days).
- **Monitoring:** job failures alert IT; a backup older than 26 h is an incident.

## Nightly job

[`scripts/windows/backup-mysql.ps1`](../scripts/windows/backup-mysql.ps1) (Task Scheduler,
runs as the backup service account):

1. `mysqldump --defaults-extra-file=<option file> --single-transaction --routines --triggers
   --events --source-data=2 otueke` -> compressed file with UTC timestamp.
2. Verify the dump completed (exit code, trailing "Dump completed" line).
3. Flush and copy binary logs.
4. Copy to NAS; encrypted copy to offsite storage.
5. Prune by retention; write a log line to the event log.

## Restore - full

1. Declare an incident (see [incident response](incident-response.md)); stop the API service so
   no new writes occur.
2. Provision an empty MySQL 8.4 instance with the standard config.
3. Decrypt/copy the chosen full backup; `mysql --defaults-extra-file=<admin option file> < dump.sql`.
4. Run API health checks; start the API service.

## Restore - point in time (PITR)

1. Restore the latest full backup before the target time (above).
2. Read the binlog position recorded in the dump header (`--source-data=2`).
3. Replay binlogs from that position up to just before the bad event:
   `mysqlbinlog --start-position=<pos> --stop-datetime="YYYY-MM-DD HH:MM:SS" <binlogs> | mysql ...`
   (times in **UTC**).
4. Validate totals (e.g. day's sales per operating point) with the finance lead before reopening.
5. Coordinate with cloud sync: the API's sync process must reconcile after a restore - follow
   the API release notes; never edit sync tables manually.

## Quarterly restore test

- Restore last night's backup + binlogs to an isolated test instance (not the live server).
- Record: duration (RTO), data loss window (RPO), row counts of key tables, issues.
- File the result in the site record; failed tests are incidents.

Targets (proposal): **RPO <= 15 minutes**, **RTO <= 4 hours** for the site database.
