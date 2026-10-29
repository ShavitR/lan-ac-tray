# LAN AC Tray

A small Windows notification-area app for controlling compatible Wi-Fi air conditioners on your local network. It runs in the tray overflow under **^** and communicates directly over the LAN; it has no browser interface or vendor cloud connection.

## Compatibility

This release discovers **GREE / EWPE-compatible** air conditioners that answer the local UDP protocol on port 7000. It handles common AES-ECB and AES-GCM handshake variants. Some rebranded units may work, but Wi-Fi air conditioners do not share one universal protocol; units using Tuya or another vendor protocol are not supported by this release. The AC must already be connected to the same local network as the PC. The app does not set up the AC's Wi-Fi connection.

The protocol research is informed by [tomikaa87/gree-remote](https://github.com/tomikaa87/gree-remote) and [eibenp/homebridge-gree-airconditioner](https://github.com/eibenp/homebridge-gree-airconditioner). Device compatibility can vary by Wi-Fi module and firmware.

LAN AC Tray is an independent community project and is not affiliated with an air-conditioner manufacturer.

## Install and run

1. Install **PowerShell 7.4 or newer** on Windows 10 or 11. See [Microsoft's installation guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows).
2. Download the ZIP from the [latest release](https://github.com/ShavitR/lan-ac-tray/releases/latest) and extract it to a folder that will stay in place.
3. Double-click `Start-Lan-AC-Tray.vbs`.
4. Find **LAN AC Tray** in the taskbar overflow (**^**), right-click it, and choose **Settings…**.
5. Choose **Scan network**, select a compatible device, name it, and choose **Pair and use selected**.

Keep the extracted folder in place if you enable **Start when I sign in to Windows**. The app then adds a shortcut to your personal Startup folder. Starting the app only reads the AC's current status; it does not turn the AC on. Power changes happen only after a user action.

## Controls

- Left-click the tray icon to toggle the selected AC.
- Right-click for power, temperature, mode, fan, Settings, refresh, and exit.
- Settings can select or forget a saved device, scan for more compatible devices, pair one, and enable or disable sign-in startup.
- Status refreshes every 15 seconds. Choose **Refresh** to retry immediately.

## Troubleshooting

- Make sure the PC and AC are on the same local network. Guest networks, Wi-Fi client isolation, VPN routing, and router settings can block local discovery.
- Discovery broadcasts to UDP port 7000 on active Ethernet and Wi-Fi interfaces, then listens for local replies. A firewall rule may be needed if Windows blocks discovery or replies.
- If the scan finds nothing, the AC may use an unsupported protocol or firmware. This app cannot configure the AC's Wi-Fi credentials.
- If a device is found but pairing fails, confirm that it is GREE / EWPE-compatible and still connected to the network, then scan again.

## Privacy

The app sends device discovery and control messages only on the local network. It has no telemetry and does not contact a vendor cloud service. Paired names and device IDs are stored in `%APPDATA%\LanAcTray\devices.json` in the current Windows profile; this file is excluded from the repository. Do not include local IP addresses, MAC addresses, Wi-Fi names, or packet captures in public issues.

## Contributing

Bug reports, device compatibility notes, and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one. Use the private reporting path in [SECURITY.md](SECURITY.md) for security concerns.

## License

This project is available under the [MIT License](LICENSE).
