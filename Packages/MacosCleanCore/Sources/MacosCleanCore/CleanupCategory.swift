import Foundation

/// How risky it is to delete a category.
public enum Safety: String, Sendable, Codable, CaseIterable {
    case safe
    case caution

    /// First scan ticks every item of a `.safe` category and none of a `.caution` one.
    public var selectedByDefault: Bool { self == .safe }

    public var label: LocalizedStringResource {
        switch self {
        case .safe: LocalizedStringResource("Safe", bundle: #bundle, comment: "Badge on a cleanup category that is safe to delete.")
        case .caution: LocalizedStringResource("Caution", bundle: #bundle, comment: "Badge on a cleanup category the user should review before deleting.")
        }
    }
}

/// A storage-waste location group shown in the Storage Manager.
public struct CleanupCategory: Identifiable, Sendable {
    public enum Source: Sendable {
        /// Fixed paths (may start with `~`).
        case paths([String])
        /// Resolved at scan time from `app_junk_db.json` (`safe_caches`).
        case appCaches
        /// Discovered at scan time by walking for code projects.
        case devProjects
        /// Simulator runtimes and devices listed by `simctl`; removed with `simctl`, not the Trash.
        case simulators
    }

    /// Items of this category are removed for good with `simctl` instead of going to the Trash.
    public var isRemovedWithSimctl: Bool {
        if case .simulators = source { true } else { false }
    }

    public let id: String
    public let name: LocalizedStringResource
    public let details: LocalizedStringResource
    public let safety: Safety
    public let source: Source
}

extension CleanupCategory {
    /// Built-in cleanup categories shown in Storage Manager.
    public static let all: [CleanupCategory] = [
        CleanupCategory(
            id: "user-caches",
            name: LocalizedStringResource("User Application Caches", bundle: #bundle),
            details: LocalizedStringResource("Cached data from installed apps. Safe to delete; apps regenerate as needed.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches"])
        ),
        CleanupCategory(
            id: "user-logs",
            name: LocalizedStringResource("User Logs", bundle: #bundle),
            details: LocalizedStringResource("Application log files written by macOS apps. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Logs"])
        ),
        CleanupCategory(
            id: "trash",
            name: LocalizedStringResource("Trash", bundle: #bundle),
            details: LocalizedStringResource("Files already in the Trash. Empty it, or pick items to delete for good.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.Trash"])
        ),
        CleanupCategory(
            id: "xcode-derived",
            name: LocalizedStringResource("Xcode DerivedData", bundle: #bundle),
            details: LocalizedStringResource("Xcode build intermediates and indexes. Often 20–50 GB. Rebuilds on next compile.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Developer/Xcode/DerivedData"])
        ),
        CleanupCategory(
            id: "xcode-archives",
            name: LocalizedStringResource("Xcode Archives", bundle: #bundle),
            details: LocalizedStringResource("Archived builds for distribution. Review before deleting — needed for symbolication of shipped releases.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/Library/Developer/Xcode/Archives"])
        ),
        CleanupCategory(
            id: "xcode-device-support",
            name: LocalizedStringResource("Xcode iOS DeviceSupport", bundle: #bundle),
            details: LocalizedStringResource("Symbols copied from connected iPhones, iPads, Apple Watches, Apple TVs and Vision Pros. Old versions can be deleted; Xcode copies them again when that device connects.", bundle: #bundle),
            safety: .safe,
            source: .paths([
                "~/Library/Developer/Xcode/iOS DeviceSupport",
                "~/Library/Developer/Xcode/watchOS DeviceSupport",
                "~/Library/Developer/Xcode/tvOS DeviceSupport",
                "~/Library/Developer/Xcode/visionOS DeviceSupport",
                "~/Library/Developer/Xcode/xrOS DeviceSupport",
            ])
        ),
        CleanupCategory(
            id: "simulator-caches",
            name: LocalizedStringResource("iOS Simulator Caches", bundle: #bundle),
            details: LocalizedStringResource("Cached data for the iOS Simulator. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Developer/CoreSimulator/Caches"])
        ),
        CleanupCategory(
            id: "simulators",
            name: LocalizedStringResource("Simulator Runtimes & Devices", bundle: #bundle),
            details: LocalizedStringResource("iOS, watchOS, tvOS and visionOS simulator runtimes, and simulator devices with their app data. Removed with Xcode's simctl — this can't be undone. Runtimes can be downloaded again in Xcode › Settings › Components.", bundle: #bundle),
            safety: .caution,
            source: .simulators
        ),
        CleanupCategory(
            id: "xcode-previews",
            name: LocalizedStringResource("SwiftUI Previews Data", bundle: #bundle),
            details: LocalizedStringResource("Simulator devices and builds Xcode creates for SwiftUI previews. Safe to delete; Xcode recreates them the next time a preview runs.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Developer/Xcode/UserData/Previews"])
        ),
        CleanupCategory(
            id: "spm-cache",
            name: LocalizedStringResource("Swift Package Manager Cache", bundle: #bundle),
            details: LocalizedStringResource("Resolved Swift packages. Safe to delete; will re-resolve on next build.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm"])
        ),
        CleanupCategory(
            id: "cocoapods-cache",
            name: LocalizedStringResource("CocoaPods Cache", bundle: #bundle),
            details: LocalizedStringResource("Cached CocoaPods downloads. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/CocoaPods"])
        ),
        CleanupCategory(
            id: "npm-cache",
            name: LocalizedStringResource("npm Cache", bundle: #bundle),
            details: LocalizedStringResource("npm download cache. Safe to delete (or run `npm cache clean --force`).", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.npm"])
        ),
        CleanupCategory(
            id: "yarn-cache",
            name: LocalizedStringResource("Yarn Cache", bundle: #bundle),
            details: LocalizedStringResource("Yarn v1 global cache. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/Yarn", "~/.yarn/cache"])
        ),
        CleanupCategory(
            id: "pnpm-store",
            name: LocalizedStringResource("pnpm Store", bundle: #bundle),
            details: LocalizedStringResource("pnpm content-addressable store. Safe to delete or prune.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.pnpm-store", "~/Library/pnpm/store", "~/.local/share/pnpm/store"])
        ),
        CleanupCategory(
            id: "pip-cache",
            name: LocalizedStringResource("pip Cache", bundle: #bundle),
            details: LocalizedStringResource("Python pip download/wheel cache. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/pip", "~/.cache/pip"])
        ),
        CleanupCategory(
            id: "poetry-cache",
            name: LocalizedStringResource("Poetry Cache", bundle: #bundle),
            details: LocalizedStringResource("Python Poetry cache. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/pypoetry", "~/.cache/pypoetry"])
        ),
        CleanupCategory(
            id: "homebrew-cache",
            name: LocalizedStringResource("Homebrew Cache", bundle: #bundle),
            details: LocalizedStringResource("Downloaded bottles and source archives. Safe to delete (or `brew cleanup`).", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/Homebrew", "/Library/Caches/Homebrew"])
        ),
        CleanupCategory(
            id: "gradle-cache",
            name: LocalizedStringResource("Gradle Cache", bundle: #bundle),
            details: LocalizedStringResource("Gradle build cache, downloaded dependencies and Gradle wrapper distributions. Safe to delete; stop Gradle first (`gradle --stop`).", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.gradle/caches", "~/.gradle/wrapper/dists"])
        ),
        CleanupCategory(
            id: "cargo-cache",
            name: LocalizedStringResource("Cargo Registry Cache", bundle: #bundle),
            details: LocalizedStringResource("Rust crate download cache. Safe to delete.", bundle: #bundle),
            safety: .safe,
            source: .paths([
                "~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/registry/index",
                "~/.cargo/git/db", "~/.cargo/git/checkouts",
            ])
        ),
        CleanupCategory(
            id: "bun-cache",
            name: LocalizedStringResource("Bun Cache", bundle: #bundle),
            details: LocalizedStringResource("Bun's global package download cache. Safe to delete; Bun downloads packages again on the next install.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.bun/install/cache"])
        ),
        CleanupCategory(
            id: "uv-cache",
            name: LocalizedStringResource("uv Cache", bundle: #bundle),
            details: LocalizedStringResource("Python packages and wheels cached by uv. Safe to delete; quit any running uv command first.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.cache/uv", "~/Library/Caches/uv"])
        ),
        CleanupCategory(
            id: "go-build-cache",
            name: LocalizedStringResource("Go Build Cache", bundle: #bundle),
            details: LocalizedStringResource("Compiled Go packages and test results. Safe to delete; Go rebuilds them on the next build. The Go module cache isn't listed: its files are read-only, so use `go clean -modcache`.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/go-build"])
        ),
        CleanupCategory(
            id: "deno-cache",
            name: LocalizedStringResource("Deno Cache", bundle: #bundle),
            details: LocalizedStringResource("Downloaded and compiled Deno modules. Safe to delete; Deno fetches them again.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/deno", "~/.cache/deno"])
        ),
        CleanupCategory(
            id: "dart-pub-cache",
            name: LocalizedStringResource("Dart & Flutter Pub Cache", bundle: #bundle),
            details: LocalizedStringResource("Packages downloaded by `dart pub` and `flutter pub`. Safe to delete; run `pub get` to restore. Globally activated tools aren't touched.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/.pub-cache/hosted", "~/.pub-cache/git"])
        ),
        CleanupCategory(
            id: "browser-test-downloads",
            name: LocalizedStringResource("Playwright & Puppeteer Browsers", bundle: #bundle),
            details: LocalizedStringResource("Browser builds downloaded for automated testing. Safe to delete; `playwright install` or Puppeteer downloads them again.", bundle: #bundle),
            safety: .safe,
            source: .paths(["~/Library/Caches/ms-playwright", "~/.cache/ms-playwright", "~/.cache/puppeteer"])
        ),
        CleanupCategory(
            id: "electron-cache",
            name: LocalizedStringResource("Electron & node-gyp Downloads", bundle: #bundle),
            details: LocalizedStringResource("Electron binaries, electron-builder tools and Node.js headers for native modules. Safe to delete; they download again on the next build.", bundle: #bundle),
            safety: .safe,
            source: .paths([
                "~/Library/Caches/electron", "~/Library/Caches/electron-builder",
                "~/Library/Caches/node-gyp", "~/.cache/node-gyp",
            ])
        ),
        CleanupCategory(
            id: "maven-repository",
            name: LocalizedStringResource("Maven Local Repository", bundle: #bundle),
            details: LocalizedStringResource("Java dependencies downloaded by Maven. Review before deleting: it can also hold artifacts you installed with `mvn install` that can't be downloaded again.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/.m2/repository"])
        ),
        CleanupCategory(
            id: "nuget-packages",
            name: LocalizedStringResource("NuGet Packages", bundle: #bundle),
            details: LocalizedStringResource(".NET packages and NuGet's download cache. Review before deleting: it can hold packages you built locally.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/.nuget/packages", "~/.local/share/NuGet/http-cache"])
        ),
        CleanupCategory(
            id: "docker-data",
            name: LocalizedStringResource("Docker Desktop Data", bundle: #bundle),
            details: LocalizedStringResource("Docker images, containers and volumes. Use `docker system prune -a` for a safe clean.", bundle: #bundle),
            safety: .caution,
            source: .paths([
                "~/Library/Containers/com.docker.docker/Data/vms",
                "~/Library/Group Containers/group.com.docker",
            ])
        ),
        CleanupCategory(
            id: "claude-data",
            name: LocalizedStringResource("Claude Caches & History", bundle: #bundle),
            details: LocalizedStringResource("Regenerable caches, logs, and session/conversation history for Claude Desktop and the Claude CLI. Clearing these frees space and does NOT sign you out or change your settings, but you'll lose local chat/session history. Review before deleting.", bundle: #bundle),
            safety: .caution,
            source: .paths([
                // Claude Desktop (Electron) caches & logs
                "~/Library/Caches/com.anthropic.claudefordesktop",
                "~/Library/Application Support/Claude/Cache",
                "~/Library/Application Support/Claude/Code Cache",
                "~/Library/Application Support/Claude/GPUCache",
                "~/Library/Application Support/Claude/DawnGraphiteCache",
                "~/Library/Application Support/Claude/DawnWebGPUCache",
                "~/Library/Application Support/Claude/logs",
                "~/Library/Application Support/Claude/local-agent-mode-sessions",
                "~/Library/Logs/Claude",
                // Claude CLI caches & local history
                "~/Library/Caches/claude-cli-nodejs",
                "~/.claude/projects",
                "~/.claude/todos",
                "~/.claude/shell-snapshots",
                "~/.claude/statsig",
            ])
        ),
        CleanupCategory(
            id: "local-ai-logs",
            name: LocalizedStringResource("Ollama & LM Studio Logs", bundle: #bundle),
            details: LocalizedStringResource("Logs and app caches of Ollama and LM Studio. Safe to delete; models, chats and settings aren't touched.", bundle: #bundle),
            safety: .safe,
            source: .paths([
                "~/.ollama/logs",
                "~/Library/Caches/ollama",
                "~/Library/Caches/com.electron.ollama",
                "~/Library/WebKit/com.electron.ollama",
                "~/.lmstudio/server-logs",
            ])
        ),
        CleanupCategory(
            id: "local-ai-history",
            name: LocalizedStringResource("Ollama & LM Studio History", bundle: #bundle),
            details: LocalizedStringResource("Your Ollama prompt history and LM Studio conversations. These can't be recreated. Review before deleting.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/.ollama/history", "~/.lmstudio/conversations"])
        ),
        CleanupCategory(
            id: "local-ai-models",
            name: LocalizedStringResource("Downloaded AI Models", bundle: #bundle),
            details: LocalizedStringResource("Models downloaded by LM Studio and Hugging Face tools. Often many GB each; they can be downloaded again, but that can take a long time. Remove Ollama models with `ollama rm` instead.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/.lmstudio/models", "~/.cache/lm-studio/models", "~/.cache/huggingface/hub"])
        ),
        CleanupCategory(
            id: "ios-backups",
            name: LocalizedStringResource("iOS Device Backups", bundle: #bundle),
            details: LocalizedStringResource("Local backups of iPhones/iPads via Finder. Review before deleting.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/Library/Application Support/MobileSync/Backup"])
        ),
        CleanupCategory(
            id: "ios-updates",
            name: LocalizedStringResource("iOS Software Updates", bundle: #bundle),
            details: LocalizedStringResource("iPhone and iPad software files (.ipsw) Finder downloaded to update or restore a device. Safe to delete; Finder downloads them again when needed.", bundle: #bundle),
            safety: .safe,
            source: .paths([
                "~/Library/iTunes/iPhone Software Updates",
                "~/Library/iTunes/iPad Software Updates",
                "~/Library/iTunes/iPod Software Updates",
            ])
        ),
        CleanupCategory(
            id: "app-caches",
            name: LocalizedStringResource("App Caches (Popular Apps)", bundle: #bundle),
            details: LocalizedStringResource("Cache folders popular apps hide outside ~/Library/Caches — browser Code Caches, Slack/Discord/VS Code Electron caches, Adobe Media Cache, Steam htmlcache. Quit the app before cleaning; everything regenerates.", bundle: #bundle),
            safety: .safe,
            source: .appCaches
        ),
        CleanupCategory(
            id: "dev-projects",
            name: LocalizedStringResource("Developer Project Leftovers", bundle: #bundle),
            details: LocalizedStringResource("Regenerable build output and dependency folders inside your code projects — node_modules, Rust/Maven target, __pycache__, .gradle, Pods, DerivedData, .next, and git-ignored build/dist/vendor dirs. All come back with a reinstall or rebuild. Review before deleting.", bundle: #bundle),
            safety: .caution,
            source: .devProjects
        ),
        CleanupCategory(
            id: "system-downloads",
            name: LocalizedStringResource("Old Downloads", bundle: #bundle),
            details: LocalizedStringResource("Items in ~/Downloads. Review carefully before deleting.", bundle: #bundle),
            safety: .caution,
            source: .paths(["~/Downloads"])
        ),
    ]
}
