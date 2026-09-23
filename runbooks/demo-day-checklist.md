# Demo-day checklist: live mobile app + offline Local server, end to end

> **DRAFT.** Goal (MVP): a real Flutter mobile app talking to the **Local node** over the property LAN, still working with the internet
> unplugged, with the **Cloud node** following (sync/heartbeat). Two ways to run the Local node - pick one and stick to it on the day:
>
> - **A. Demo laptop** (macOS/Linux, `scripts/dev/local-node.sh`) - fastest, no property server needed.
> - **B. Property Windows server** (`scripts/windows/*`) - the real thing; needs the install done days before.

Owner of each line: write initials + time when done. Anything not ticked by T-30 min changes the plan to the fallback at the bottom.

## T-7 days: build the pieces

- [ ] Release package built from a tagged commit (`build-release-package.yml`): `r007-<sha>.zip` (Local) and `.tar.gz` (Cloud); **the same tag on both nodes**.
- [ ] Cloud VPS bootstrapped + provisioned + first deploy done ([server installation](server-installation.md) B); `https://<cloud>/up` OK; TLS valid; ports scan clean.
- [ ] Local server (B) installed and first deploy done; **or** laptop (A) prepared: Homebrew MySQL 8.4 + Redis running (`brew services start mysql@8.4 redis`), PHP 8.4/8.5 + Composer, checkout of `007resort-api`.
- [ ] Node credential issued for the demo site; Local `.env` has `SYNC_PEER_URL` + credential; Cloud has the site in `SYNC_ACCEPT_SITES`.
- [ ] Demo seeder exists and runs on a scratch DB (staff/NFC/PIN accounts, facilities, menu, tickets, slots, stock). Seeded credentials written on the **presenter's card**, not in chat.
- [ ] Mobile app build pointing at the **LAN server URL** (QR/`Server` setting) and installed on the demo phone(s)/tablet(s) (TestFlight/APK). Cleartext-to-LAN allowed; iOS Local Network permission accepted once.
- [ ] Backup + restore-test done once ([backup and restore](backup-and-restore.md)); results noted.

## T-2 days: rehearse the full path (twice)

- [ ] Fresh install rehearsal on a spare machine/VM: dry-run, install, deploy, `status.ps1` green after **reboot**.
- [ ] Devices: DHCP reservation/name for the server (`r007-api.site.local`) - or the laptop's IP is fixed for the day (router reservation); tablets join the right Wi-Fi ([device onboarding](device-registration.md)); mobile data **off** on demo devices.
- [ ] Rehearse the demo script below start to finish, with the **WAN unplugged** in the middle. Time it. Fix what breaks; note it here.
- [ ] `update.ps1 -Rollback` / `r007-deploy rollback` rehearsed once (so nobody fears the button).

## T-1 day: freeze

- [ ] **Code + deploy freeze** after the last rehearsal: no new release, no migration. Record the deployed version on both nodes (`/api/v1/system/info`).
- [ ] Fresh backup on both nodes; NAS/off-site copy confirmed; laptop demo DB re-seeded and snapshotted (`mysqldump` to a file) so it can be reset in a minute.
- [ ] Devices charged, chargers/USB-C/Lightning packed, spare phone with the app installed, printed QR of the server URL, Wi-Fi password card.
- [ ] Sync heartbeat green on Cloud (site ONLINE); outbox depth 0.
- [ ] Rotate nothing, change nothing.

## Morning of: bring-up (T-90 to T-30 min)

**A. Laptop Local node**

```bash
scripts/dev/local-node.sh up --fresh          # (--fresh only if you want the DB reset; drops ONLY r007_* databases)
scripts/dev/local-node.sh status              # serve, queue, scheduler, reverb RUNNING, /up OK, redis OK
scripts/dev/local-node.sh url                 # LAN URL + QR for tablets
```

**B. Windows server**

```powershell
C:\R007\scripts\status.ps1                    # must exit 0
```

- [ ] `http://<server>/up` returns OK **from the demo phone's browser on the demo Wi-Fi** (this is the real test, not the laptop's localhost).
- [ ] `/api/v1/system/info` says `local`; version = frozen version.
- [ ] App logs in (NFC/PIN or password), device registered, correct facility/operating point.
- [ ] Reverb live: change something on device 1, watch it appear on device 2/KDS without refresh.
- [ ] Cloud shows the site ONLINE with a fresh heartbeat; `wss://<cloud>/app/...` reachable.
- [ ] Disk space, laptop power plugged in, sleep disabled (`caffeinate -dimsu` on macOS), notifications off, screen mirroring tested.

## Demo script (~15 min)

1. **Online, normal:** sign in on the mobile app; open a table/tab, add items; KDS shows the ticket in real time; take a **cash** payment; receipt.
2. **Booking + ticket:** create a facility booking / sell a pool ticket; scan/validate the QR at the "gate" device; show it cannot be validated twice.
3. **Cloud view:** on the Cloud admin/dashboard show the same sales (sync working; freshness label).
4. **Pull the plug:** unplug the WAN (router/uplink; laptop: turn off its internet **but keep the Wi-Fi/LAN up** - use a router with WAN unplugged, not "Wi-Fi off").
   Confirm the phone stays connected to the Wi-Fi, mobile data is off.
5. **Offline trading:** repeat step 1 and 2 with new orders/tickets. Everything still works; show `status.ps1` / `system/info` outbox depth growing and the Cloud site turning stale/OFFLINE after ~90 s.
6. **Plug back in:** heartbeat resumes, outbox drains to 0, Cloud now shows the offline orders (idempotent, no duplicates). Show the audit trail for one order.
7. **Fail safe (optional, impressive):** stop a worker (`Stop-Service R007-Queue` / `local-node.sh stop`-then-`up`), show it recover by itself (NSSM/Supervisor restart) - only if rehearsed.

## Fallbacks (decide beforehand, tell the audience nothing)

| Problem | Fallback |
| --- | --- |
| Phone shows "no internet", app cannot reach LAN | mobile data off; forget/re-join Wi-Fi; try IP URL instead of name; second phone |
| DNS name fails | use `http://<ip>`; keep IP on the QR |
| Cloud unreachable | continue Local-only demo (that *is* the offline story); show outbox queueing |
| A service is red | `status.ps1` / `local-node.sh status` -> restart the named service; bad release -> rollback |
| Data got messy | reset laptop DB from the T-1 snapshot (1 minute); Windows: `restore-mysql.ps1 -Live` from the T-1 backup |
| Everything on fire | laptop Local node (A) with the seeded snapshot - keep it ready even if you demo on B |

## After

- [ ] Restore normal state: WAN plugged, outbox 0, `status.ps1` green; record issues found (each -> a ticket) and what saved the day.
- [ ] Remove demo credentials/devices; rotate anything shared on the day ([rotation](node-credential-rotation.md)).
