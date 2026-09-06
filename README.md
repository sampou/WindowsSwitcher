# Windows Switcher

<p align="center">
  <img src="WindowsSwitcher/Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" alt="Windows Switcher logo" width="128">
</p>

<p align="center">
  <a href="https://github.com/sampou/WindowsSwitcher/releases"><img src="https://img.shields.io/github/v/release/sampou/WindowsSwitcher?color=blue&label=Version" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift" alt="Swift 5.9 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"></a>
</p>

<p align="center">
  English · <a href="README_CN.md">简体中文</a>
</p>

Windows Switcher is a native macOS window switcher inspired by the Windows Alt+Tab experience. It combines complete window thumbnails, fuzzy search, configurable ordering, same-app switching, Dock previews, and keyboard-driven window layouts.

## Features

### Window switching

- Press **Option+Tab** to open the switcher and preview all discovered windows.
- Cycle forward with Tab, cycle backward with Shift+Tab, and release Option to activate the selected window.
- Sort by most recently used, application name, window title, or application group.
- Configure preview size and grid columns, and optionally include minimized or hidden windows.
- Navigate with the keyboard or mouse while keeping the selected item visible.

### Same-app switching

- Press **Option+`** to cycle through windows owned by the current application.
- Hold Shift for reverse traversal.
- Enable, disable, or remap the shortcut in Settings.

### Dock previews

- Hover over a Dock icon to see that application's windows.
- Hover over an item for a larger preview, or click it to activate the window.
- Configure delays, preview count, dimensions, spacing, icons, and animation.

### Window layouts

- Move or resize a target window to the left, right, top, or bottom half; any quarter; maximized; centered; previous display; or next display.
- Open the standalone layout panel with **Control+Option+L**.
- Use Tab or the arrow keys to select a row, Enter or Space to apply it, and Escape to close the panel.
- Click anywhere on a layout row to apply it. Applying a layout changes geometry without activating the target window.
- Right-click the menu bar icon to access the same layout actions and current shortcuts.
- Configure every layout shortcut globally. The panel, Settings, and menu bar use the same shortcut notation.

### Native macOS experience

- Light, dark, and system appearance modes.
- Simplified Chinese and English localization, with a Settings option to follow macOS or choose either language for the app.
- SwiftUI interfaces integrated with AppKit panels, Carbon global hotkeys, Accessibility APIs, and ScreenCaptureKit.
- Persistent settings, window activity ordering, launch-at-login support, and update checking.

## Requirements

| Requirement | Minimum |
| --- | --- |
| macOS | 13.0 Ventura |
| Build tools | Xcode with Swift 5.9 or later |

The installed app needs the following macOS permissions:

| Permission | Purpose |
| --- | --- |
| Accessibility | Discover, activate, move, resize, and close windows; support global interaction |
| Screen Recording | Capture live window thumbnails and previews |

Grant them under **System Settings → Privacy & Security**. If previews or window operations do not start immediately after authorization, quit and reopen Windows Switcher.

## Installation

The packaged app is the supported way to install and run Windows Switcher because macOS permissions are associated with the signed application bundle.

1. Download the latest DMG from [GitHub Releases](https://github.com/sampou/WindowsSwitcher/releases).
2. Open the DMG and drag **WindowsSwitcher.app** to **Applications**.
3. Launch the app and grant Accessibility and Screen Recording permissions.

A ZIP artifact is also published for environments where DMG mounting is unavailable.

## Default shortcuts

All shortcuts can be changed in **Settings → Shortcuts**.

| Action | Default |
| --- | --- |
| Open window switcher | Option+Tab |
| Reverse window switching | Option+Shift+Tab |
| Switch within current app | Option+` |
| Reverse same-app switching | Option+Shift+` |
| Open layout panel | Control+Option+L |
| Left / right half | Control+Option+← / → |
| Top / bottom half | Control+Option+↑ / ↓ |
| Top-left / top-right quarter | Control+Option+U / I |
| Bottom-left / bottom-right quarter | Control+Option+J / K |
| Maximize / center | Control+Option+Return / C |
| Previous / next display | Control+Option+Command+← / → |

## Menu bar

- **Left-click:** open the window switcher.
- **Right-click:** open a menu containing the switcher, window layouts, Settings, and Quit.
- The window layout submenu resolves the frontmost eligible window as its target and keeps the target fixed while the menu is open.

## Settings

- **General:** launch behavior, update options, and appearance.
- **Switcher:** hidden/minimized windows, initial selection, and background preview.
- **Preview:** thumbnail size and grid columns.
- **Dock:** Dock preview behavior and presentation.
- **Shortcuts:** switcher, same-app, layout enablement, and every layout key combination.
- **About:** version and application information.

## Build and test

Clone the repository and run the test suite:

```bash
git clone https://github.com/sampou/WindowsSwitcher.git
cd WindowsSwitcher
swift test --package-path WindowsSwitcher
```

For development-only command-line builds:

```bash
swift build --package-path WindowsSwitcher
```

For permission-sensitive validation, build the signed app bundle and DMG with the project script instead of running the bare SwiftPM executable:

```bash
bash scripts/build-release.sh 0
```

The script:

- increments `CFBundleVersion` (and increments the patch version by the numeric argument);
- builds a universal `arm64 + x86_64` Release app and signs it with `WindowsSwitcher Local Signing` by default;
- creates ZIP and DMG candidates in `build/`, then publishes both to `release/` only after validation;
- writes a release manifest, SHA-256 checksum file, and per-run logs under `.release-logs/`;
- restores version metadata and transactionally restores the previous same-version release if packaging fails;
- installs the validated app to `/Applications/WindowsSwitcher.app` and launches it.

Set `WINDOWSSWITCHER_SIGN_IDENTITY` to use another local signing identity. The default backend is direct `hdiutil`; `auto` is a compatibility alias for the same backend. Finder styling through `create-dmg` is available only when explicitly selected with `WINDOWSSWITCHER_DMG_BACKEND=create-dmg`. Before compiling, the script performs a small DMG creation preflight and stops within 20 seconds if DiskImages is unhealthy. It rejects concurrent runs and publishes a DMG only after checking its UDIF signature, verifying it, mounting it, inspecting the app, and validating the app signature. It never renames an ISO image as a DMG.

For an external distribution release, first store App Store Connect credentials in Keychain and use a Developer ID Application certificate. Do not put the password, issuer ID, or private-key path in the script or repository:

```bash
xcrun notarytool store-credentials "WindowsSwitcher-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"

WINDOWSSWITCHER_RELEASE_MODE=distribution \
WINDOWSSWITCHER_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAM_ID)" \
WINDOWSSWITCHER_NOTARY_PROFILE="WindowsSwitcher-notary" \
WINDOWSSWITCHER_VERSION="0.0.187" \
WINDOWSSWITCHER_BUILD_NUMBER="201" \
bash scripts/build-release.sh 0
```

Distribution mode requires a clean worktree, a monotonically increasing build number, hardened-runtime signing with a secure timestamp, successful Apple notarization of both the app and DMG, stapled tickets, and Gatekeeper assessment. A deliberately reviewed dirty-tree release must opt in with `WINDOWSSWITCHER_ALLOW_DIRTY=1`. Verify downloaded artifacts from `release/` with `shasum -a 256 -c WindowsSwitcher-<version>.sha256`.

If the script reports a stale WindowsSwitcher disk-image session, eject every `Windows Switcher` volume in Finder and retry. Restart macOS first if DiskImages still retains an unmounted session; the script detects this condition before changing the version or build number.

If a previous shell was forcibly terminated and left `.build-release.lock`, first confirm that no `build-release.sh` process is running, then retry once with `WINDOWSSWITCHER_FORCE_UNLOCK=1`. Never force-unlock while another release is active.

> A successful release changes the build number and replaces the installed application. A failed release restores the original version metadata.

## Project structure

```text
WindowsSwitcher/
├── WindowsSwitcher/
│   ├── Sources/                 # Application source
│   ├── Resources/               # Asset catalog
│   └── Tests/                   # SwiftPM tests
├── scripts/build-release.sh     # Signed/notarized ZIP/DMG build and install
├── tools/user-e2e/              # User-level smoke tests
└── docs/CHANGELOG.md            # Release history
```

## Documentation and links

- [Change log](docs/CHANGELOG.md)
- [User E2E smoke tests](tools/user-e2e/README.md)
- [GitHub releases](https://github.com/sampou/WindowsSwitcher/releases)
- [GitHub issues](https://github.com/sampou/WindowsSwitcher/issues)
- [Gitee mirror](https://gitee.com/sampou/WindowsSwitcher)
- [MIT License](LICENSE)

## Contributing

Issues and pull requests are welcome. Please run `swift test --package-path WindowsSwitcher` before submitting code changes.
