# Runbook: internet outage at the site

> **DRAFT** - pending architecture approval.

The platform is **local-first**: the on-site server is authoritative for on-site operations, so
an internet outage must not stop trading.

## What continues locally

- POS sales, cash payments, order entry, KDS routing and kitchen printing.
- Walk-in bookings and check-ins at Reception (via the on-site API booking engine).
- Pool tickets sold on site and QR validation against the local API.
- Inventory movements, staff sign-in, shift open/close, local admin-web and reporting on local data.
- Card payments **only** if the payment terminal has its own connectivity (e.g. SIM fallback) or
  supports offline authorisation - per provider rules.

## What degrades

- **Online booking / online payments:** `007resort-booking-web` keeps running in the cloud, but new
  online bookings reach the site only when sync resumes. Risk of conflicts for the same slot is
  handled by the API sync/conflict rules (per architecture); Reception should check pending
  online bookings after recovery.
- Remote admin (cloud) shows data only up to the last successful sync.
- Offsite backup copies are delayed (local + NAS backups continue).
- Email/SMS confirmations and any cloud-only integrations are queued.

## Response

1. **Confirm** the outage (ISP status, firewall WAN status). Log start time.
2. **Inform** duty manager and Reception: online bookings may arrive late; card terminals may be
   affected.
3. **Check** the API sync status page/log: sync should be queuing, not erroring locally.
4. If card payments are unavailable: switch to cash / approved alternative per finance policy.
5. For long outages (> 4 h): consider temporarily closing online booking for same-day slots via
   the admin UI (API feature, when available) to reduce conflict risk.
6. **Do not** expose the server via alternative connections (mobile hotspot, port forwarding).

## Recovery

1. Confirm WAN is stable; sync resumes automatically (outbound).
2. Watch the sync backlog drain; resolve any conflicts reported by the API.
3. Reception reviews online bookings received during the outage.
4. Verify offsite backup copy runs.
5. Record outage duration and impact in the incident log.
