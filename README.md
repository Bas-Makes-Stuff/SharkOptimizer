# SharkOptimizer

A free Windows optimizer with Windows tweaks, game profiles, repair tools, and system checks in one app. Version 2.0.2 uses a native C# / WPF interface. Older 1.x releases use PowerShell.

> Made by Bas. Available in English, Nederlands, Español, Deutsch, Français, Português (Brasil), Русский and 简体中文.

## Download

Download **`SharkOptimizer-Setup.exe`** from the [latest GitHub release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest), then run the installer. It installs SharkOptimizer, adds a Start Menu entry, offers an optional Desktop shortcut, and includes an uninstaller.

Current public release: **2.0.2**, with five main navigation entries, grouped tweak cards, green borders for enabled settings, and focused Game Boost and utility views.

The installer is not code-signed. If SmartScreen appears, confirm that you downloaded the setup file from this official repository before choosing **More info > Run anyway**.

## Features

- **Windows tweaks** arranged by category, with risk labels and warnings for sensitive changes.
- **Hardware-aware recommendations** that explain when a tweak does not fit your PC.
- **Game profiles** with suggested Windows settings, plus the option to add another game.
- **Presets** for saving and reusing selected tweaks.
- **Windows tools** for repair, startup apps, built-in app removal, and closing heavy apps.
- **Boost-Up cleanup** for temporary files and caches, with optional scheduled cleanup.
- **Lab tools** for before and after benchmarks, system checks, tweak verification, and profile import/export.
- **Network tools** including ping tests, DNS benchmarking, and traceroute.
- **Restore support** with restore point guidance and undo for tracked changes.
- **Eight languages**, accent color choices, and a system report for troubleshooting.
- **Animated launcher** with startup checks and a useful error report.

The native app also includes a background scan of existing Windows tweaks, a compact dashboard with live CPU/GPU/RAM readings, close-to-tray behavior, and background GitHub update downloads that wait for installation confirmation. Existing tweaks detected outside SharkOptimizer are separate from its undo history; settings that cannot be read reliably stay unverified.

## Quick start

1. Download and run `SharkOptimizer-Setup.exe` from the [latest release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest).
2. Choose an installation folder and whether to create a Desktop shortcut.
3. Start SharkOptimizer from the Start Menu or Desktop shortcut and approve the administrator prompt.
4. Create a restore point from the Dashboard before applying changes.
5. Review the recommended tweaks or choose a preset, then apply the changes you want.
6. Use **Details** on a tweak to see what it changes. Use **Restore** to undo changes later.

Change the language with the language button or in **Settings**. The in-app Guide provides more detail.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (included with Windows)
- Administrator rights when applying system changes
- Internet access is optional; the app uses its bundled Poppins fonts

## Source layout

| Path | Purpose |
|------|---------|
| `Start-SharkOptimizer.bat` | Starts the legacy PowerShell launcher |
| `legacy/` | Preserved PowerShell app and launcher sources |
| `legacy/fonts/` | Bundled Poppins fonts shared with the native app |
| `legacy/shark.ico` | Shared app and installer icon source |
| `installer/` | Installer source, manifest, and build script |
| `native/` | C# / WPF app source, manifest, build script, and generated `out/` executable |
| `shared/` | Shared Windows startup registration code |
| `tools/` | Version validation, version changes, and source packaging |
| `.github/workflows/release.yml` | Windows build and tag-triggered release workflow |
| `release/<version>/SharkOptimizer-Setup.exe` | Locally built installer candidate |

The legacy app stores settings, logs, and undo information in `C:\ProgramData\SharkOptimizer`. The native app stores its state under `%LOCALAPPDATA%\SharkOptimizer` and imports supported legacy data. Portable backups preserve app preferences and profiles; they do not apply Windows changes or replace undo history.

Build the native candidate from a source checkout:

```powershell
.\native\extract-translations.ps1
.\native\build.ps1
.\installer\build-installer.ps1 -NativeAppPath .\native\out\SharkOptimizer.Native.exe -OutputPath .\release\2.0.2\SharkOptimizer-Setup.exe
.\tools\Assert-ReleaseVersion.ps1 -AppPath .\native\out\SharkOptimizer.Native.exe -SetupPath .\release\2.0.2\SharkOptimizer-Setup.exe
```

The installer embeds the native app. Version 2.0.2 is published with one uploaded installer asset. See [native/README.md](native/README.md) for implementation details and [RELEASE-GUIDE.md](RELEASE-GUIDE.md) for future updates. The automatic download and confirmed installation flow was verified from 2.0.0 to 2.0.1; the updater also downloaded and verified the published 2.0.2 installer.

## Uninstall

Uninstall from **Settings > Apps > Installed apps** or **Control Panel > Programs and Features**. Applied tweaks remain after uninstalling. Use **Restore > Undo All Tweaks** first if you want to restore saved Windows values.

## Safety

SharkOptimizer can change Windows settings, registry values, services, and network adapter options. Review each change and its warning before applying it. Some advanced changes can affect Windows features or security.

## License and copyright

Copyright © 2026 Bas Makes Stuff. All rights reserved.

SharkOptimizer is proprietary software. You may use the official app, but reuse, modification, redistribution, and sale of its code or original assets require written permission. See [LICENSE](LICENSE). Third-party fonts and icons retain their own licenses.

## Third-party credits

- Font: [Poppins](https://fonts.google.com/specimen/Poppins), licensed under the SIL Open Font License.
- SharkOptimizer is an independent project and is not affiliated with Hone, ExitLag, GearUP Booster, Microsoft, NVIDIA, AMD, Riot Games, Epic Games, Valve, or other companies mentioned in the app.
