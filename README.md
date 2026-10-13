# SharkOptimizer

A free Windows optimizer written in PowerShell. SharkOptimizer groups Windows tweaks, game profiles, repair tools, and system checks in one app. Changes are recorded so you can review and undo them.

> Made by Bas. Available in English, Nederlands, Español, Deutsch, Français, Português (Brasil), Русский and 简体中文.

## Download

Download **`SharkOptimizer-Setup.exe`** from the [latest GitHub release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest), then run the installer. It installs SharkOptimizer, adds a Start Menu entry, offers an optional Desktop shortcut, and includes an uninstaller.

Current version: **1.5.1**.

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
| `Start-SharkOptimizer.bat` | Starts the PowerShell launcher |
| `data/SharkOptimizer-Launcher.ps1` | Loading screen and startup checks |
| `data/SharkOptimizer.ps1` | Main application |
| `data/fonts/` | Bundled Poppins fonts |
| `data/shark.ico` | App and installer icon |
| `installer/` | Installer source, manifest, and build script |
| `SharkOptimizer-Setup.exe` | Installer attached to the GitHub release |

Settings, logs, and undo information are stored in `C:\ProgramData\SharkOptimizer`.

## Uninstall

Uninstall from **Settings > Apps > Installed apps** or **Control Panel > Programs and Features**. Applied tweaks remain after uninstalling. Use **Restore > Undo All Tweaks** first if you want to restore saved Windows values.

## Safety

SharkOptimizer can change Windows settings, registry values, services, and network adapter options. Review each change and its warning before applying it. Some advanced changes can affect Windows features or security.

## Credits

- Font: [Poppins](https://fonts.google.com/specimen/Poppins), licensed under the SIL Open Font License.
- SharkOptimizer is an independent project and is not affiliated with Hone, ExitLag, GearUP Booster, Microsoft, NVIDIA, AMD, Riot Games, Epic Games, Valve, or other companies mentioned in the app.

