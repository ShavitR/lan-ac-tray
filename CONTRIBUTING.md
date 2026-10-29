# Contributing

Bug reports, compatibility reports, documentation improvements, and focused pull requests are welcome.

## Before opening an issue

- Check existing issues and the [supported-device notes](README.md#compatibility).
- Use the bug or feature form so maintainers have the information needed to respond.
- Redact local IP addresses, MAC addresses, Wi-Fi network names, device IDs, packet captures, and other personal information. Do not upload the contents of `%APPDATA%\LanAcTray\devices.json`.
- This release supports GREE / EWPE-compatible devices only. A device being Wi-Fi-connected does not mean it uses a compatible protocol.

## Development setup

1. Use Windows 10 or 11 with PowerShell 7.4 or newer.
2. Clone the repository and keep `LanAcTray.ps1` next to `Start-Lan-AC-Tray.vbs`.
3. Run `Start-Lan-AC-Tray.vbs` to launch the tray app. The app stores test pairings in your own Windows profile, not in the repository.

The app is a PowerShell and Windows Forms project and does not require third-party modules. Keep the tray interface native and concise, keep device settings local, and do not add vendor cloud access or automatic power changes at startup.

## Pull requests

- Keep each change focused and describe the user problem it solves.
- Update the README or help text when behavior, compatibility, or setup changes.
- For another device protocol, include public protocol references and identify the tested device family and firmware. Do not claim support for a brand based only on a model name.
- Include the checks you ran and clearly say when a change was not tried with physical hardware.
- Do not commit local pairing files, network identifiers, credentials, packet captures, or user-specific paths.
- Contributions are covered by the MIT License; no separate contributor agreement is required.

## Manual checks

For PowerShell changes, parse the script before opening a pull request:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\LanAcTray.ps1), [ref]$null, [ref]$errors) | Out-Null
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }
```

When a compatible AC is available, check that the tray starts without changing AC power, Settings can scan and list devices, a selected device can be paired, and status refresh works. Only try power, temperature, mode, or fan changes on a device you are authorized to control. Do not run device-control checks in CI.
