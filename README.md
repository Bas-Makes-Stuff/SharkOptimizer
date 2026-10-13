# SharkOptimizer

A free, open PC optimizer for Windows 10 and 11, written in PowerShell. It matches tweaks to your hardware, has game profiles, repair tools and a before/after benchmark, and **every change can be undone**.

> Made by Bas. Available in English, Nederlands, Español, Deutsch, Français, Português (Brasil), Русский and 简体中文.

## Download

For most people, download **`SharkOptimizer-Setup.exe`** from the [latest release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest) and run it. The installer creates a Start Menu entry, can create a Desktop shortcut, and includes an uninstaller.

The installer is currently not code-signed. If Windows SmartScreen appears, click **More info** and then **Run anyway** only if you downloaded it from this official GitHub repository. The current release is [SharkOptimizer V1.5.0](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/tag/1.5.0).

## Features

- **96 tweaks** in clear categories: Privacy & Security, Quality of Life, FPS & Latency, Network & Ping, Windows Optimization and Advanced.
- **Risk tags** on every tweak: SAFE, CAUTION or CORE WINDOWS CHANGE, with a warning before anything risky is applied.
- **Matched to your PC**: tweaks that don't suit your hardware (for example NVIDIA-only or SSD-only ones) are greyed out and explained.
- **10 game profiles** (VALORANT, Fortnite, CS2, Apex Legends, Warzone, FiveM / GTA V, Roblox, Rocket League, Overwatch 2, Rust) with tips and recommended tweaks, plus an **Add Game** button for any other game. Games with anti-cheat only get Windows-level changes. The app never touches game files or game processes.
- **My Presets**: save your own tweak selections and share them with a short code.
- **Windows tools**: repair tools, startup app manager, built-in app removal and a heavy-app closer.
- **Boost-Up**: cleaners for temp files, caches and more, plus an optional **weekly cleanup** through Windows Task Scheduler.
- **Lab**: before/after benchmark, Game Mode, system check, tweak verification, profile export/import and a live ping graph.
- **Network tools**: region ping test, DNS benchmark and traceroute.
- **Restore points and undo** for everything it changes.
- **8 languages**, switchable at any time, and a choice of accent colours (blue, green, purple, orange).
- **Copy System Report**: one click copies your specs, applied tweaks and recent log lines (your username is hidden), which makes problems easy to report.
- An animated loading screen with startup checks and a clear error report.

## Quick start

1. Go to the [latest release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest), download **`SharkOptimizer-Setup.exe`** under **Assets**, and run it.
2. In the installer, choose whether to create a Desktop shortcut, then finish installation.
3. Start SharkOptimizer from the Start Menu or Desktop shortcut. Click **Yes** on the Windows administrator prompt. A loading screen appears, then the app opens.
4. On the **Dashboard**, click **Create Restore Point** first.
5. Click **Apply Recommended**, or pick a **Preset** and review it on the Tweaks page.
6. On **Tweaks**, tick what you want and click **Apply Selected**. Use **Details** on any card to see exactly what it changes.
7. On **Games**, click **Scan for Games** (or **Add Game**), pick a game and click **Optimize**.
8. In the **Lab**, click **Run BEFORE**, apply your tweaks, restart if asked, then click **Run AFTER** to see what changed.
9. To go back, use the **Restore** tab (**Undo All Tweaks**) or **Reset to Windows Defaults** in the Lab.

Change the language with the language button at the top right, or in **Settings** (the gear icon). The in-app **Guide** (the `?` button) walks you through the same steps.

### Snel starten (NL)

1. Ga naar de [laatste release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest), download **`SharkOptimizer-Setup.exe`** onder **Assets** en voer het uit.
2. Kies in de installer of je een snelkoppeling op je bureaublad wilt, en rond de installatie af.
3. Start SharkOptimizer via het Startmenu of de snelkoppeling. Klik op **Ja** bij de beheerdersmelding.
4. Maak eerst een herstelpunt op het Dashboard. Gebruik daarna **Aanbevolen toepassen** of kies zelf tweaks.
5. Taal wisselen kan met de taalknop rechtsboven of via **Instellingen**.

## Languages

English and Nederlands are fully translated. Español, Deutsch, Français, Português (Brasil), Русский and 简体中文 translate the menus, buttons, labels and all tweak names. Longer descriptions, warnings and the in-app guide are still in English for those six languages. Corrections are welcome as issues or pull requests.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built into Windows)
- Administrator rights (the app asks for them itself)
- Internet only on first start, to download the Poppins font. Without internet it uses Segoe UI.

## Files

| File | What it does |
|------|--------------|
| `SharkOptimizer-Setup.exe` | Recommended installer, available on the Releases page |
| `SharkOptimizer.ps1` | The app source |
| `SharkOptimizer-Launcher.ps1` | Animated loading screen, startup checks and error report |
| `Start-SharkOptimizer.cmd` | Portable/manual starter |
| `shark.ico` | Icon (optional) |

Settings, logs and undo information are stored in `C:\ProgramData\SharkOptimizer`.

## Uninstalling

Uninstall SharkOptimizer from **Settings > Apps > Installed apps** or **Control Panel > Programs and Features**. Tweaks you applied stay active after uninstalling. Open SharkOptimizer first and use **Restore > Undo All Tweaks** if you want to return them to their saved original values. The installer will remind you about this.

## Troubleshooting

- **"Windows protected your PC":** click **More info > Run anyway** only when the installer came from this official GitHub repo.
- **The app closes on start:** the loading screen shows the error with **Copy details** and **Open logs** buttons. Open an issue and paste the text.
- **Something feels off after a tweak:** open **Restore**, undo the last tweak you applied, and restart.
- **Reporting a problem:** open **Settings > Help and data > Copy System Report** and paste the result into your issue.

## Safety

SharkOptimizer changes Windows settings, the registry, services and network adapter options. It records the old value of every change so it can restore it, and it offers a restore point before risky tweaks. Even so, use it at your own risk and read the warnings. Tweaks marked **CORE WINDOWS CHANGE** can affect security or features (for example IPv6, Xbox services, CPU mitigations or virtualization).

## Credits

- Font: [Poppins](https://fonts.google.com/specimen/Poppins), licensed under the SIL Open Font License.
- Inspired by the features of game optimizers such as Hone. SharkOptimizer is an independent project and is not affiliated with Hone, ExitLag, GearUP Booster, Microsoft, NVIDIA, AMD, Riot Games, Epic Games, Valve or any other company mentioned.

## Copyright and license

Copyright (c) 2026 Bas (Bas-Makes-Stuff). Released under the [MIT License](LICENSE).
