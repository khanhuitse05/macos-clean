# macOS Clean

A native macOS 26 utility built with **Swift 6** and **SwiftUI** to reclaim disk space safely. It scans caches, developer leftovers, large files, duplicates, and uninstalled-app remnants — and moves items to the Trash first instead of deleting them permanently.

## Features

- **Storage Manager**: Scans 26 cleanup categories (user caches/logs, Xcode DerivedData/Archives/DeviceSupport, iOS simulators, SwiftPM/CocoaPods/npm/pnpm/Yarn/pip/Poetry/Homebrew/Gradle/Cargo caches, Docker Desktop data, popular app caches, and git-aware developer project leftovers), split into **Safe** and **Caution** tiers.
- **Large Files**: Fast directory walking (`getattrlistbulk` via `DirectoryWalker`) with size thresholds, exclusions, and Quick Look previewing.
- **Duplicates**: Detects identical files using size grouping and edge/full `CryptoKit` hashing while skipping hard links.
- **File Browser**: Multi-column browser with instant folder sizing and prefetched child listings.
- **Uninstaller**: Lists installed apps, detects leftover preferences/caches/logs/supporting files via a curated `app_junk_db.json`, and watches `/Applications` for recently removed apps.
- **Trash & History**: Review and empty `~/.Trash` safely in-app, track cleaning history, configure excluded folders, and interact with **Bubbl** (a Reduce Motion–aware floating mascot).

## Safety & Privacy

- **Trash-first**: `Cleaner` moves selected paths to the Trash via `FileManager.trashItem` and enforces an explicit `confirm: true` guard plus protected system/home paths.
- **Strict permanent deletion**: `TrashEmptier` is the only code path that permanently removes files, and it refuses anything outside `~/.Trash` (preventing symlink escapes).
- **100% local**: Zero analytics, zero telemetry, and no network calls from the app.

## Download & Install

Prebuilt Universal binaries (Apple Silicon & Intel), signed with Developer ID and notarized by Apple, are available on [GitHub Releases](https://github.com/khanhuitse05/macos-clean/releases/latest).

1. Download `macos-clean.dmg` and drag **macOS Clean.app** into `/Applications`.
2. Grant **Full Disk Access** in **System Settings › Privacy & Security › Full Disk Access** so macOS Clean can inspect protected app caches and containers.
3. Reopen the app and run a scan.

## Building from Source

### Prerequisites

- **macOS 26.0+**
- **Xcode** with Swift 6 toolchain
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`)

### Local Debug Build

The Xcode project is generated from `project.yml`. Debug builds use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), so no Apple Developer certificate is required:

```bash
git clone https://github.com/khanhuitse05/macos-clean.git
cd macos-clean
xcodegen generate
open macos-clean.xcodeproj
```

Or build from the terminal:

```bash
xcodegen generate
xcodebuild -project macos-clean.xcodeproj -scheme macos-clean -configuration Debug build
```

> **Note:** Full Disk Access is tied to an app's code signature. Ad-hoc Debug builds may need Full Disk Access re-granted after rebuilding. For Release signing with your own Apple Developer team, override `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` or via `xcodebuild` arguments.

## Running Tests

Unit tests live in the `MacosCleanCore` Swift package:

```bash
xcrun swift test --package-path Packages/MacosCleanCore
```

Using `xcrun` ensures SwiftPM uses the active Xcode SDK and toolchain.

## Project Layout

```text
macos-clean/
├── App/                        # SwiftUI macOS application & mascot UI
├── Packages/MacosCleanCore/    # Swift 6 core scanning, cleaning & app-uninstaller library + tests
├── web/                        # Landing page & interactive web demo (published to gh-pages)
├── fastlane/                   # Fastlane build, notarization & GitHub release automation
├── scripts/                    # DMG packaging & Apple notarytool helper scripts
├── Design/                     # Source app icon artwork
└── project.yml                 # XcodeGen project specification
```

## Contributing

Issues and pull requests are welcome. Before opening a PR:

1. Run `xcrun swift test --package-path Packages/MacosCleanCore` and confirm all tests pass.
2. Build the `macos-clean` scheme in Xcode to verify `App/` compiles cleanly.

## License

Released under the [MIT License](LICENSE).
