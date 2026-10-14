# GitHub releases and future updates

The source and workflow are uploaded to `codex/native-2.0.0-review` in [draft PR #2](https://github.com/Bas-Makes-Stuff/SharkOptimizer/pull/2). The initial 2.0.0 hosted build passed. Latest policy corrections are being checked before release. Installation, uninstall/reinstall, tray reopening, sign-in startup, CPU sampling, and first-launch/saved language behavior have been checked on the development PC. Merge and first publication still require approval; a complete newer-version update needs verification against the published native release.

## First publication

1. Upload the native source, `installer/`, `shared/`, `tools/`, `VERSION`, language resources, and `.github/workflows/release.yml`. Include the `legacy/` icon, fonts, and PowerShell source used as data by the translation generator. Generated `native/out/`, installer output, previews, local state, and compiled installers belong outside source commits.
2. Run the workflow on the source branch and inspect the result. Confirm the installer behaves correctly on a clean installation and an existing installation.
3. After approval, merge the source and workflow, then push the matching version tag `v2.0.0`. Tag pushes publish a release automatically after build checks succeed. Branch pushes, pull requests, and manual workflow runs produce review artifacts without publishing a release.
4. The public release contains one uploaded asset: `SharkOptimizer-Setup.exe`. GitHub's own source archives are also available automatically.

## Future versions

From a checked-out repository:

```powershell
.\tools\Set-Version.ps1 -Version 2.0.1
```

Add `release-notes/2.0.1.md`, make and check the changes, commit the source, and push it. After the checks and release review, push the matching tag:

```powershell
git tag -a v2.0.1 -m "SharkOptimizer 2.0.1"
git push origin v2.0.1
```

GitHub builds the native app and installer, validates the versions, runs isolated checks, and publishes the installer. The workflow uses GitHub's built-in token; a personal token is not needed for publishing from Actions.

The app reads the official repository's latest stable release. Automatic checks run after startup and every six hours while the app is running. With automatic downloads enabled, it downloads and checks the installer in the background, shows an update-ready action, and waits for confirmation before closing to install. Both update preferences are saved and included in setup backups.

Do not reuse a published version tag or replace an existing public release installer. Give each new release a new version and tag.
