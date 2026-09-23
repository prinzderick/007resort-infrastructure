# Runbook: device onboarding (POS, tablets, KDS, printers) on the property LAN

> **DRAFT** - pending architecture approval.

Every operational device is registered **in the 007 Resort & Spa API** and mapped into the hierarchy
`Property -> Facility -> Operating Point -> Terminal -> Staff -> Transaction`. An unregistered device cannot transact.
This runbook covers the **network side** (address, name, Wi-Fi) and how a device finds the Local node; the
registration screens themselves live in the apps/admin-web.

## How devices find the server (the one thing that must be right)

Devices always talk to the **Local node**, by a stable name, never by a cloud URL:

| Item | Value (proposal - confirm per site) |
| --- | --- |
| Server IP | static on SERVER VLAN, e.g. `10.10.10.10` (never DHCP) |
| DNS name | `r007-api.site.local` -> that IP, published by the firewall/router resolver (or the server's DNS role). Create the record **before** onboarding devices |
| API base URL (what apps are configured with) | `http://r007-api.site.local` (or `https://...` when an internal-CA certificate is installed - `install.ps1 -CertThumbprint`) |
| Reverb (WebSocket) | `ws://r007-api.site.local:8085` (`wss://` only when TLS is terminated for it) |
| Health check | `http://r007-api.site.local/up` |

Options for getting the URL into a device, best first:

1. **Managed / QR provisioning:** IT prints a QR (or an MDM profile) that encodes the API base URL; the app's first-run screen scans it. Print one on the tablet dock/charging shelf as a fallback.
   The demo script `scripts/dev/local-node.sh url` prints the same QR for the dev/demo node.
2. **Typed once:** enter `http://r007-api.site.local` in the app's *Server* setting during onboarding (kept in secure storage).
3. **Direct IP** (`http://10.10.10.10`) only as an emergency fallback if DNS fails - and fix DNS afterwards.

mDNS/Bonjour discovery does **not** cross VLANs, so it is not relied upon. Tablets and the server are on different VLANs
(OPS 20 / STAFF 40 vs SERVER 10): the firewall must allow OPS/STAFF -> server on tcp/80 (443) and tcp/8085 only
([network segmentation](../network/logical-segmentation.md)); the server's own firewall enforces the same subnets.

## Network preparation

- Device is on the inventory list (asset tag, serial, MAC).
- **DHCP reservation** (MAC-based) on the correct VLAN: POS/KDS/printers/scanners/tablets -> POS/OPERATIONS (20); back-office workstations -> STAFF (40). Reserved addresses make firewall logs and the device register meaningful.
- **Wi-Fi:** tablets join `R007-OPS` (VLAN 20; WPA3-Enterprise, or PSK + MAC allow-list). Staff laptops join `R007-STAFF` (VLAN 40). Guests never touch these SSIDs. Client isolation is *off* on OPS only where devices must reach printers; the firewall still limits what they may reach.
- **Wi-Fi with no internet (outage or by design):** Android/iOS may decide the network is "not connected" and route app traffic over mobile data - which cannot reach a LAN address.
  On managed tablets remove SIM/disable mobile data; otherwise disable *Switch to mobile data automatically / Smart network switch* and set the OPS network to "keep connected".
  Test this in the outage rehearsal.
- **Cleartext HTTP on the LAN:** the mobile apps must allow it for the LAN name (Android `networkSecurityConfig` domain allow for `r007-api.site.local`;
  iOS `NSAllowsLocalNetworking`/ATS exception plus the *Local Network* permission prompt). Prefer HTTPS with an internal CA where feasible.
- Verify from the device: browser -> `http://r007-api.site.local/up` returns OK; `.../api/v1/system/info` reports `local`; **ports 3306/6379 do not answer.**

## Steps

1. **Network:** device on `R007-OPS`/OPS switch port, gets its reserved IP; the URL check above passes.
2. **OS baseline:** latest OS updates, screen lock, kiosk / assigned access where applicable, unused apps removed, USB mass storage disabled on POS.
3. **Install the client** (POS desktop / mobile / KDS) from the approved release channel.
4. **Point it at the server** (QR / typed URL, above).
5. **Register in the API** (enrolment screen or admin-web): facility, operating point, terminal name (`POS-03`, `TAB-11`), type, asset tag.
   The API issues a **device credential** stored in the device's secure storage - never written down or shared.
6. **Printers:** register printer IP and routing (receipt vs kitchen station) against the operating point; printers are DHCP-reserved on OPS (tcp/9100 from the server).
7. **Test:** sign in as a test staff member; run a zero-value/test transaction or print a test ticket; confirm it shows under the correct terminal in reports.
   Then **turn the WAN off** (or just disable the server's uplink) and repeat once - it must still work.
8. **Record** asset tag, MAC, IP, VLAN, terminal, operating point, installer, date in the device register.

## Decommissioning / loss

1. Revoke the device credential in the API immediately (lost/stolen = incident, see [incident response](incident-response.md)).
2. Remove the DHCP reservation and MAC allow-list entry.
3. Wipe the device before reuse or disposal; update the device register.
