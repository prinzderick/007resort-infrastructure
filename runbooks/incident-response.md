# Runbook: incident response

> **DRAFT** - pending architecture approval.

## Severity

| Sev | Examples | Response |
| --- | --- | --- |
| SEV1 | Local node cannot trade (server/DB/API down), suspected data breach, ransomware, payment data exposure, Cloud site-wide outage | Immediate; IT lead + owner/manager notified |
| SEV2 | One facility down, **sync stalled > 1 h** or outbox backlog growing, **backup failed / older than 26 h**, **restore test failed**, lost/stolen device, Cloud OFFLINE-flapping | Within 1 hour |
| SEV3 | Single device fault, printer issue, minor defect with workaround | Next business day |

## First response (all severities)

1. **Stabilise trading** - fall back (another terminal, cash, manual docket) per operating procedures. The Local node trades without the Cloud; do not "fix" the Cloud by touching Local.
2. **Open an incident record**: time (local + UTC), reporter, node (Local/Cloud), affected facility/operating point/terminals, symptoms.
3. **Preserve evidence** - do not reboot/wipe suspect machines before IT decides. Export logs first:
   Local `C:\R007\logs\*`, `C:\R007\shared\storage\logs\*`, Windows Event Log, IIS logs; Cloud `/var/log/r007/*`, `storage/logs`, `journalctl -u nginx -u php8.4-fpm -u mysql`, `/var/log/auth.log`, `fail2ban-client status sshd`.
4. **Communicate** - duty manager informs staff; IT lead updates the record.

## Triage commands

```powershell
C:\R007\scripts\status.ps1            # Local: every service, task, port, /up, system/info + heartbeat, backup age, disk
Get-Service R007-*, R007MySQL, Memurai, W3SVC
Get-Content C:\R007\logs\R007-Queue.err.log -Tail 100
```
```bash
sudo supervisorctl status ; r007-deploy status ; curl -fsS http://127.0.0.1:8088/up     # Cloud
tail -n 100 /var/log/r007/queue.log /var/www/r007/shared/storage/logs/laravel-*.log
```

## Specific playbooks

- **API down (Local):** `status.ps1` -> which check fails? IIS: `iisreset`, `Restart-WebAppPool R007`; workers: `Restart-Service R007-Queue,R007-Sync,R007-Reverb`
  (NSSM already restarts crashes - repeated crashes = read `*.err.log`); MySQL: `Restart-Service R007MySQL`, check `logs\mysql-error.log` and free disk;
  Redis: `Restart-Service Memurai`. Bad release: `update.ps1 -Rollback`. SEV1 if not restored in 15 min.
- **API down (Cloud):** `supervisorctl status`, `systemctl status nginx php8.4-fpm mysql redis-server`; bad deploy: `r007-deploy rollback`; disk/RAM (`df -h`, `free -m`).
- **Queue/sync stalled:** workers running? Redis up? Cloud reachable (`Test-NetConnection <cloud host> -Port 443`)? Node credential rejected (401 in sync log) -> [credential rotation](node-credential-rotation.md).
  Do not clear queues or edit outbox tables by hand; use the admin-web retry/reprocess action (permission-gated and audited).
- **Database corruption / bad data change:** stop workers and web, follow [backup and restore](backup-and-restore.md) (PITR). Never fix business data with ad-hoc SQL; only approved, reviewed changes.
- **Backup failed / stale:** run it by hand (`backup-mysql.ps1` / `r007-backup`), read `backup.log`, check disk, NAS reachability/credentials, rclone remote. Open SEV2 until a verified backup exists.
- **Suspected compromise / leaked secret:** isolate (disconnect network, do not power off), **rotate** affected secrets ([rotation runbook](node-credential-rotation.md): node credential, DB/Redis passwords,
  Reverb keys, Paystack, deploy keys, device credentials), review access logs, notify the owner; assess legal notification duties (data-protection authority, Paystack).
  Ransomware: isolate, do not pay/negotiate ad hoc, restore from the **off-site** copy onto clean hardware.
- **Lost/stolen device:** revoke its device credential in the API ([device onboarding](device-registration.md)); review recent transactions.
- **Internet outage:** [internet outage](internet-outage.md).
- **Certificate expiry (Cloud):** `sudo certbot renew --dry-run`, `systemctl status certbot.timer`; renewals reload nginx via the deploy hook.

## Close-out

- Confirm service restored and data reconciled (sales totals, stock, bookings, sync backlog 0, backup fresh).
- Post-incident review within 5 working days for SEV1/SEV2: timeline, root cause, actions, owners, due dates. Update runbooks and scripts.
