# Runbook: device registration

> **DRAFT** - pending architecture approval.

Every operational device (POS terminal, tablet, KDS screen, printer, scanner) is registered
**in the Otueke API** and mapped into the hierarchy:

```
Property -> Facility -> Operating Point -> Terminal -> Staff -> Transaction
```

A device that is not registered cannot transact.

## Before you start

- Device is on the device inventory list (asset tag, serial, MAC).
- DHCP reservation created on the correct VLAN (POS/OPS for POS, tablets, KDS, printers) - see
  [network segmentation](../network/logical-segmentation.md).
- You have an IT/admin account with the device-management permission in the API.

## Steps

1. **Network:** connect the device to `Otueke-OPS` Wi-Fi or the OPS switch port; confirm it gets
   its reserved IP and can reach `https://otueke-api.site.local:5443/health`.
2. **OS baseline:** latest OS updates, screen lock, kiosk/assigned-access mode where applicable,
   remove unused apps, disable USB mass storage on POS where possible.
3. **Install the client** (POS desktop / mobile / KDS app) from the approved release channel.
4. **Register in the API** (admin-web or the app's enrolment screen, when available):
   - Assign facility and operating point (e.g. Pool Facility -> Pool Bar).
   - Set terminal name (e.g. `POS-03`), type, and asset tag.
   - The API issues a device credential; it is stored in the device's secure storage - never
     written down or shared.
5. **Printers:** register printer, IP, and routing (receipt vs. kitchen station) against the
   operating point.
6. **Test:** sign in as a test staff member, run a zero-value/test transaction or print a test
   ticket, confirm it appears under the correct terminal in reports.
7. **Record** in the device register: asset tag, MAC, IP, VLAN, terminal name, operating point,
   installer, date.

## Decommissioning / loss

1. Revoke the device credential in the API immediately (lost/stolen devices: treat as an incident).
2. Remove DHCP reservation and MAC allow-list entry.
3. Wipe the device before reuse or disposal; update the device register.
