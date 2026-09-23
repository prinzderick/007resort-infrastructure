# Runbook: node-to-node credential rotation (Local <-> Cloud sync)

> **DRAFT** - pending architecture approval. Basis: architecture/17 section 7.1, ADR-0013. The node credential is
> distinct from any staff/customer/device credential and is stored in `.env` - so it can be rotated **without a deployment**.

Direction of trust: the **Local node calls the Cloud** (outbound HTTPS, `SYNC_PEER_URL`), presenting `SYNC_NODE_CREDENTIAL`.
The Cloud stores only a hash/verifier for each accepted site (`SYNC_ACCEPT_SITES`). Cloud never connects into the property.

## When to rotate

- Scheduled: at least every 90 days (proposal), and whenever a person with access to the credential leaves.
- Immediately (as an incident): suspected leak, lost/stolen server, an unexpected site appearing in Cloud sync logs, backup media lost (they contain encrypted `.env`, but rotate anyway).
- After restoring the server from backup onto new hardware.

## Zero-downtime rotation (overlap window)

The API must accept **two** credentials for a site during the overlap (current + next). If the release in use does not
support that yet, use the "hard cut" variant below and accept a short sync pause - the outbox holds events safely.

1. **Prepare (Cloud admin, admin-web or artisan on the VPS as `deploy`):** issue a *new* credential for the site
   (API command/endpoint provided by `007resort-api`; it prints the plaintext **once**). Do not write it in tickets or chat;
   copy it directly into the vault entry "R007 node credential - <site>".
2. **Cloud accepts both** (old + new) - confirm in the admin-web that the site has two active credentials.
3. **Local (elevated PowerShell on the server):** replace only `SYNC_NODE_CREDENTIAL`, rebuild the config cache (it is cached, so a
   plain restart would keep the old value) and restart the workers:
   ```powershell
   . C:\R007\scripts\lib\R007.Common.ps1
   $v = Read-R007SecretPrompt 'New node credential'          # typed/pasted at a hidden prompt, never echoed or logged
   Set-R007EnvValue C:\R007\shared\.env SYNC_NODE_CREDENTIAL $v; Remove-Variable v
   Set-Location C:\R007\current; & C:\R007\tools\php\php.exe artisan config:cache
   Restart-Service R007-Queue, R007-Sync, R007-Reverb
   ```
4. **Verify:** `status.ps1` -> `/api/v1/system/info` shows a fresh heartbeat/last-sync after ~1 minute; the Cloud site-health page shows ONLINE; outbox depth 0.
5. **Revoke the old credential** on the Cloud; confirm sync still works; record date, who, reason in the site record. Shred any temporary copies.

## Hard cut (no overlap support)

1. Issue new credential on Cloud with the old one **disabled at the same moment** (or accept old = invalid immediately).
2. Local: update `.env`, `config:cache`, restart services as above **within minutes**. Until then the site shows OFFLINE at Cloud and the
   outbox queues (no data is lost). Do this at a quiet time and never during an online-booking peak.

## Related secrets - same procedure family

| Secret | Where | Rotate by |
| --- | --- | --- |
| `REVERB_APP_SECRET/KEY` | both `.env` | change on the node, `config:cache`, restart Reverb/queue/IIS pool; clients reconnect (apps read the key from the API config) |
| `DB_PASSWORD`, `DB_MIGRATOR_PASSWORD` | `.env` + MySQL user | `ALTER USER ... IDENTIFIED BY` with the admin option file, update `.env`, `config:cache`, restart services |
| `REDIS_PASSWORD` | `.env` + `memurai.conf` / `redis.conf` | update both, restart Redis, then services |
| `APP_KEY` | `.env` | **do not rotate casually** - encrypted values become unreadable; needs an API-supported procedure |
| Paystack keys | Cloud `.env` only | rotate in the Paystack dashboard, update, `config:cache`, restart |
| Deploy SSH key / `VPS_SSH_KEY` | GitHub Environment secret + `authorized_keys` | add new key, update secret, remove old key |
| `age` backup key | vault | generate new pair, update `AGE_RECIPIENT`; **keep the old private key** until all backups encrypted with it expire |
| NAS credentials | `secrets\nas.cred` | change on the NAS, update file, run one backup |

After any rotation: check `status.ps1`, the Cloud heartbeat, and run one manual backup.
