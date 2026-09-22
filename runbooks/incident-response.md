# Runbook: incident response

> **DRAFT** - pending architecture approval.

## Severity

| Sev | Examples | Response |
| --- | --- | --- |
| SEV1 | Site cannot trade (API/DB down), suspected data breach, ransomware, payment data exposure | Immediate; IT lead + owner/manager notified |
| SEV2 | One facility/operating point down, sync stalled > 1 h, backup failed, lost/stolen device | Within 1 hour |
| SEV3 | Single device fault, printer issue, minor defect with workaround | Next business day |

## First response (all severities)

1. **Stabilise trading** - switch to fallback (another terminal, cash, manual docket) per
   operating procedures.
2. **Open an incident record**: time (local + UTC), reporter, affected
   facility/operating point/terminals, symptoms.
3. **Preserve evidence** - do not reboot/wipe suspected compromised machines before IT decides;
   export relevant logs (API logs `C:\R007\logs`, Windows event log, firewall logs).
4. **Communicate** - duty manager informs staff; IT lead updates the incident record.

## Specific playbooks

- **API service down:** check Windows service status and API logs; restart the service; check
  MySQL is running and disk space. Escalate to SEV1 if not restored in 15 minutes.
- **Database corruption / bad data change:** stop the API; follow
  [backup and restore](backup-and-restore.md) (PITR). Never fix business data with manual SQL
  outside an approved, reviewed change.
- **Suspected compromise / leaked secret:** isolate the machine (disconnect from network, do not
  power off), rotate affected secrets (DB passwords, signing key, sync secret, device
  credentials), review access logs, notify owner. Assess legal/regulatory notification duties
  (e.g. data protection authority, payment provider).
- **Lost/stolen device:** revoke device credential in the API
  ([device registration](device-registration.md)); review its recent transactions.
- **Internet outage:** see [internet outage](internet-outage.md).

## Close-out

- Confirm service restored and data reconciled (sales totals, stock, bookings).
- Post-incident review within 5 working days for SEV1/SEV2: timeline, root cause, actions,
  owners, due dates. Update runbooks.
