fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac test

```sh
[bundle exec] fastlane mac test
```

Run MacosCleanCore unit tests

### mac generate

```sh
[bundle exec] fastlane mac generate
```

Regenerate macos-clean.xcodeproj from project.yml

### mac build

```sh
[bundle exec] fastlane mac build
```

Archive and export Release macOS Clean.app signed with Developer ID Application

### mac package_dmg

```sh
[bundle exec] fastlane mac package_dmg
```

Notarize macOS Clean.app, package signed macos-clean.dmg, notarize & staple DMG

### mac publish_release

```sh
[bundle exec] fastlane mac publish_release
```

Copy DMG & checksum to macos-clean-release, update landing page version, commit, and push

### mac github_release

```sh
[bundle exec] fastlane mac github_release
```

Upload macos-clean.dmg to GitHub Releases via gh CLI

### mac release

```sh
[bundle exec] fastlane mac release
```

Full release pipeline: test -> Developer ID build -> notarize & DMG -> publish to release repo -> GitHub Release

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
