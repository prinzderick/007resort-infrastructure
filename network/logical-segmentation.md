# Logical network segmentation

> **DRAFT** - pending architecture approval. VLAN IDs and subnets are proposals; confirm with
> the network installer before configuration.

## Goals

- The on-site application server and database are **never reachable from the internet**.
- Guest Wi-Fi and CCTV are fully isolated from operational systems.
- Operational devices (POS, tablets, KDS, printers) can reach **only** the API on the server.
- A device failure or compromise in one segment cannot reach the others.

## VLANs

| VLAN | ID (proposed) | Subnet (proposed) | Members |
| --- | --- | --- | --- |
| SERVER | 10 | 10.10.10.0/24 | Windows application server (Otueke API, MySQL, Redis, local admin-web), NAS |
| POS/OPERATIONS | 20 | 10.10.20.0/24 | 10 POS terminals, 18 tablets, 4 KDS screens, receipt/kitchen printers, scanners |
| CCTV | 30 | 10.10.30.0/24 | Cameras, NVR |
| STAFF | 40 | 10.10.40.0/24 | Management/back-office workstations and staff laptops |
| GUEST | 50 | 10.10.50.0/23 | Guest/customer Wi-Fi (client isolation enabled) |
| MGMT (optional) | 99 | 10.10.99.0/24 | Switch/AP/firewall management interfaces |

## Allowed flows

Default policy between VLANs is **deny**. Only the flows below are permitted (stateful, return
traffic allowed).

| From \ To | SERVER | POS/OPS | CCTV | STAFF | GUEST | Internet |
| --- | --- | --- | --- | --- | --- | --- |
| **SERVER** | - | Printers: 9100/tcp (if API prints directly) | deny | deny | deny | **Outbound only**: HTTPS 443 for cloud sync, offsite backups, updates; NTP |
| **POS/OPS** | API ports only (5443/tcp; 5080/tcp only during commissioning) | Tablet/POS -> printers 9100/tcp | deny | deny | deny | deny (optional: payment terminal provider endpoints only) |
| **CCTV** | deny | deny | intra-VLAN (cameras -> NVR) | deny | deny | deny (vendor updates via change window only) |
| **STAFF** | admin-web only (443/tcp) | deny | NVR viewing only if approved | - | deny | HTTPS via firewall |
| **GUEST** | deny | deny | deny | deny | client isolation | **Internet only** (rate limited) |

Notes:

- No port forwarding / inbound NAT to the SERVER VLAN. Sync and backups are initiated
  **outbound** from the server.
- MySQL (3306) and Redis (6379) listen on localhost/SERVER VLAN only and are **not** reachable
  from POS/OPS or STAFF.
- DNS: internal resolver (firewall or server) for `*.site.local` names; GUEST uses public DNS.
- IT remote support uses an approved outbound-initiated remote tool, never inbound RDP.

## Wi-Fi (7 x Wi-Fi 6 access points)

| SSID | VLAN | Security | Notes |
| --- | --- | --- | --- |
| `Otueke-OPS` | POS/OPERATIONS (20) | WPA3-Enterprise or WPA2/3-PSK with per-device MAC allow-list | Hidden SSID optional; tablets and wireless POS |
| `Otueke-STAFF` | STAFF (40) | WPA3-Enterprise (preferred) or WPA3-Personal | Back-office laptops |
| `Otueke-Guest` | GUEST (50) | WPA3-Personal / captive portal | Client isolation, bandwidth limits |

- AP placement to cover restaurant/bar, pool, spa, sports courts, reception and kitchen; the
  kitchen and pool areas need a site survey (metal, water and heat).
- APs are managed on MGMT VLAN; the controller is not reachable from GUEST.
- CCTV cameras are wired (PoE) - no CCTV SSID.

## DHCP reservations / fixed addressing

Fixed devices get DHCP reservations (or static IPs) and are recorded in the device register
(see [device registration runbook](../runbooks/device-registration.md)):

- Application server and NAS: static IPs on SERVER VLAN.
- POS terminals, KDS screens, **printers** (all printers on POS/OPS VLAN), scanners: DHCP
  reservations on POS/OPS VLAN.
- Tablets: DHCP reservations (MAC-based) so terminals can be identified in firewall logs.
- Cameras/NVR: reservations on CCTV VLAN.

## Validation checklist

- [ ] From GUEST: server, POS, CCTV and STAFF addresses unreachable; internet works.
- [ ] From POS/OPS: only API port on server reachable; MySQL 3306 blocked.
- [ ] From STAFF: admin-web reachable; API/MySQL direct access blocked (unless approved).
- [ ] From internet: no open ports towards the site (external port scan).
- [ ] Server: outbound HTTPS to cloud API and backup target works.
