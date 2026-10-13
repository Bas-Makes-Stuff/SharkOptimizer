# SharkOptimizer

A free, open PC optimizer for Windows 10 and 11, written in PowerShell. It matches tweaks to your hardware, has game profiles, repair tools and a before/after benchmark, and **every change can be undone**.

> Made by Bas. Available in English and Nederlands.

## Download

Download the latest ready-to-use ZIP from the [Releases page](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest). The current release is [SharkOptimizer V1.3.1](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/tag/1.3.0).

## Features

- **96 tweaks** in clear categories: Privacy & Security, Quality of Life, FPS & Latency, Network & Ping, Windows Optimization and Advanced.
- **Risk tags** on every tweak: SAFE, CAUTION or CORE WINDOWS CHANGE, with a warning before anything risky is applied.
- **Matched to your PC**: tweaks that don't suit your hardware (for example NVIDIA-only or SSD-only ones) are greyed out and explained.
- **10 game profiles** (VALORANT, Fortnite, CS2, Apex Legends, Warzone, FiveM / GTA V, Roblox, Rocket League, Overwatch 2, Rust) with tips and recommended tweaks. Games with anti-cheat only get Windows-level changes. The app never touches game files or game processes.
- **Windows tools**: repair tools, startup app manager, built-in app removal and a heavy-app closer.
- **Boost-Up**: cleaners for temp files, caches and more.
- **Lab**: before/after benchmark, Game Mode, system check, tweak verification, profile export/import and a live ping graph.
- **Network tools**: region ping test, DNS benchmark and traceroute.
- **Restore points and undo** for everything it changes.
- **Dutch and English**, switchable at any time.

## Quick start

1. Go to the [latest release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest), download **SharkOptimizer.zip** under **Assets**, and unzip it somewhere permanent (for example `C:\SharkOptimizer`). Do **not** use Code > Download ZIP for normal use; that is the source-code download.
2. Start it:
   - Double-click `Start-SharkOptimizer.cmd` if the release ZIP includes it, **or**
   - right-click `SharkOptimizer-Launcher.ps1` and choose **Run with PowerShell**.
3. Click **Yes** on the Windows administrator prompt. A loading screen appears, then the app opens.
4. On the **Dashboard**, click **Create Restore Point** first.
5. Click **Apply Recommended**, or pick a **Preset** and review it on the Tweaks page.
6. On **Tweaks**, tick what you want and click **Apply Selected**. Use **Details** on any card to see exactly what it changes.
7. On **Games**, click **Scan for Games**, pick a game and click **Optimize**.
8. In the **Lab**, click **Run BEFORE**, apply your tweaks, restart if asked, then click **Run AFTER** to see what changed.
9. To go back, use the **Restore** tab (**Undo All Tweaks**) or **Reset to Windows Defaults** in the Lab.

The in-app **Guide** (the `?` button) walks you through the same steps.

### Snel starten (NL)

1. Ga naar de [laatste release](https://github.com/Bas-Makes-Stuff/SharkOptimizer/releases/latest), download **SharkOptimizer.zip** onder **Assets** en pak het uit op een vaste plek. Gebruik voor normaal gebruik **niet** Code > Download ZIP; dat is de broncode-download.
2. Dubbelklik op `Start-SharkOptimizer.cmd` als die in de release-ZIP staat, of rechtsklik op `SharkOptimizer-Launcher.ps1` en kies **Uitvoeren met PowerShell**.
3. Klik op **Ja** bij de beheerdersmelding.
4. Maak eerst een herstelpunt op het Dashboard. Gebruik daarna **Aanbevolen toepassen** of kies zelf tweaks.
5. Taal wisselen kan met de **NL/EN**-knop bovenaan of via **Instellingen**.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built into Windows)
- Administrator rights (the app asks for them itself)
- Internet only on first start, to download the Poppins font. Without internet it uses Segoe UI.

## Files

| File | What it does |
|------|--------------|
| `SharkOptimizer.ps1` | The app |
| `SharkOptimizer-Launcher.ps1` | Loading screen, startup checks and error report |
| `Start-SharkOptimizer.cmd` | Double-click starter (optional) |
| `shark.ico` | Icon (optional) |

Settings, logs and undo information are stored in `C:\ProgramData\SharkOptimizer`.

## Troubleshooting

- **"Windows protected your PC" or a blocked script:** click **More info**, then **Run anyway**. Or right-click the downloaded ZIP, choose **Properties**, tick **Unblock**, and unzip again. The scripts are plain text, so you can read them first.
- **The app closes on start:** the loading screen shows the error with **Copy details** and **Open logs** buttons. Open an issue and paste the text.
- **Something feels off after a tweak:** open **Restore**, undo the last tweak you applied, and restart.

## Safety

SharkOptimizer changes Windows settings, the registry, services and network adapter options. It records the old value of every change so it can restore it, and it offers a restore point before risky tweaks. Even so, use it at your own risk and read the warnings. Tweaks marked **CORE WINDOWS CHANGE** can affect security or features (for example IPv6, Xbox services, CPU mitigations or virtualization).

## Credits

- Font: [Poppins](https://fonts.google.com/specimen/Poppins), licensed under the SIL Open Font License.
- Inspired by the features of game optimizers such as Hone. SharkOptimizer is an independent project and is not affiliated with Hone, ExitLag, GearUP Booster, Microsoft, NVIDIA, AMD, Riot Games, Epic Games, Valve or any other company mentioned.

## Copyright and license

Copyright (c) 2026 Bas (Bas-Makes-Stuff). Released under the [MIT License](LICENSE).
