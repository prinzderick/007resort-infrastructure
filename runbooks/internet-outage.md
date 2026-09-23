# Runbook: internet outage at the property

> **DRAFT** - pending architecture approval. Basis: ADR-0005/0013, architecture/sync/*, architecture/13-offline-strategy.

The platform is **local-first**: the Local node (Windows server) is authoritative for on-site operations and keeps
running when the WAN is down. Everything below assumes the LAN, the server and its UPS are fine - if the *server*
is down that is a SEV1 ([incident response](incident-response.md)), not an outage.

## What keeps working (no internet needed)

Everything that only touches the Local node's own MySQL/Redis/Reverb, reached over the property LAN/Wi-Fi:

- Staff sign-in (NFC + PIN), device authentication, permissions, audit trail.
- POS sales, cash payments, order entry, KDS routing, kitchen/bar dispensing and printing.
- Walk-in bookings and check-ins at Reception; pool/ticket sales and QR/NFC validation against the local API.
- Inventory movements, shift open/close, biometric attendance, local admin-web and reporting on local data.
- Real-time updates (Reverb WebSocket on `ws://<server>:8085`) between tablets/KDS/POS.
- Queue workers, the scheduler, nightly backup to the NAS, and the **outbox** - events are written in the same DB
  transaction as the business change and simply wait, in order, for the Cloud to come back.
- Both mobile and desktop clients must be pointed at the **LAN address** of the Local node
  ([device onboarding](device-registration.md)) - never at a cloud URL - or they cannot work offline.

## What degrades

- **Online bookings / payments (Cloud):** the public site keeps taking bookings, but they reach the property only after
  sync resumes. Contended resources (slots, capacity) follow the offline-allocation rules
  (booking-authority-and-offline-allocation.md): Cloud may stop *immediate-fulfilment* online orders once the Local
  heartbeat is stale (~90 s = 3 missed heartbeats), and Reception must review pending online bookings after recovery.
- **Cloud dashboards** show Local data only up to the last successful sync and label it stale.
- **Card payments** only if the terminal has its own connectivity / offline authorisation; otherwise cash or the approved fallback. Paystack webhooks
  land on the Cloud, so a card payment confirmed there reaches Local only after recovery.
- Off-site backup upload is delayed (local + NAS backups continue). Email/SMS confirmations queue.
- Time: the server keeps its own clock; NTP resumes with the link. Do not "fix" the clock by hand.
- Software updates: `update.ps1` is unaffected (the package is on the server); do not deploy new releases during an outage unless required.

## Response

1. **Confirm** it is the WAN, not the LAN/server: from the server `status.ps1` (services green, `/up` OK) and `Test-NetConnection 1.1.1.1 -Port 443` fails.
   Log the start time. Check the ISP status and the firewall's WAN state.
2. **Inform** the duty manager and Reception: trading continues; online bookings may arrive late; check card terminals.
3. **Check sync is queuing, not erroring:** `status.ps1` -> `/api/v1/system/info` outbox depth grows; heartbeat/last-sync ages increase; queue and Reverb services stay running.
4. Card payments unavailable -> cash / approved alternative per finance policy.
5. Outage > 4 h -> consider closing same-day online slots from the admin UI (when available) to limit conflict risk.
6. **Do not** open the server to the internet, port-forward, or move it onto a mobile hotspot. A 4G/5G failover on the **firewall** (outbound only) is fine.
7. Phones/tablets that show "no internet" on the OPS Wi-Fi: keep them on the Wi-Fi (disable "switch to mobile data automatically"; see device onboarding notes).

## Recovery

1. WAN stable -> the site heartbeat resumes; the Cloud marks the site ONLINE; the outbox drains automatically (oldest first, idempotent by `event_id`).
2. Watch the backlog fall to 0 (`status.ps1`, Cloud site-health page). Resolve reported **conflicts** with the API/admin tooling - never by SQL.
3. Reception reviews online bookings received during the outage; finance reconciles Paystack payments confirmed on Cloud.
4. Confirm the off-site backup ran (Cloud: `backup.log`; Local: NAS copy present; if used, rclone upload).
5. Record start/end, duration, sync backlog peak and impact in the incident log. Update this runbook if reality differed.

## Rehearsal (do it before go-live and each quarter)

Pull the WAN cable for 30 minutes during a quiet period: run a full order -> KDS -> cash payment -> receipt, a walk-in booking and a ticket
validation from a tablet; then reconnect and verify the outbox drains and the Cloud shows the events. Tick it off in the
[demo-day checklist](demo-day-checklist.md) / site record.
