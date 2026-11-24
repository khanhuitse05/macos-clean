import Foundation
import Testing
@testable import MacosCleanCore

/// Timing runs for the scanners. Skipped unless `MACOS_CLEAN_BENCH=1` is set, because building
/// the synthetic tree and walking a real folder take a while:
///
///     MACOS_CLEAN_BENCH=1 /usr/bin/swift test --package-path Packages/MacosCleanCore \
///         -c release --filter ScanBenchmarks
///
/// Set `MACOS_CLEAN_BENCH_ROOT=/some/folder` to also time a real folder (e.g. `$HOME/Library`).
/// Each case runs once to warm the file-system cache, then reports the best of three runs.
@Suite("ScanBenchmarks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACOS_CLEAN_BENCH"] != nil))
struct ScanBenchmarks {
    static let synthetic: TempTree = {
        let tree = try! TempTree()
        // 2,000 folders × 50 files = 100,000 files, three levels deep.
        let payload = Data(repeating: 0xCD, count: 1_024)
        for a in 0..<20 {
            for b in 0..<10 {
                for c in 0..<10 {
                    let dir = tree.root.appendingPathComponent("a\(a)/b\(b)/c\(c)")
                    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for f in 0..<50 {
                        FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(f).bin").path, contents: payload)
                    }
                }
            }
        }
        // A few large files for the large-file scanner to find.
        for i in 0..<5 {
            FileManager.default.createFile(
                atPath: tree.root.appendingPathComponent("a\(i)/big\(i).bin").path,
                contents: Data(repeating: 0xEE, count: 2_000_000)
            )
        }
        return tree
    }()

    static func time(_ label: String, _ body: () async -> String) async {
        _ = await body()
        var best = Duration.seconds(1_000)
        var detail = ""
        for _ in 0..<3 {
            let start = ContinuousClock.now
            detail = await body()
            best = min(best, ContinuousClock.now - start)
        }
        let ms = Double(best.components.seconds) * 1_000 + Double(best.components.attoseconds) / 1e15
        print("BENCH \(label): \(String(format: "%.1f", ms)) ms  [\(detail)]")
    }

    static var realRoot: URL? {
        ProcessInfo.processInfo.environment["MACOS_CLEAN_BENCH_ROOT"].map { URL(fileURLWithPath: $0) }
    }

    @Test func measureSyntheticTree() async {
        let root = Self.synthetic.root
        await Self.time("measure synthetic 100k files") {
            "\(SizeCalculator.measure(root).bytes) bytes"
        }
    }

    @Test func listSyntheticTree() async {
        let root = Self.synthetic.root
        await Self.time("list synthetic (20 children)") {
            "\(await CategoryScanner().list(root).entries.count) entries"
        }
    }

    @Test func largeFilesSyntheticTree() async {
        let root = Self.synthetic.root
        await Self.time("large files synthetic") {
            await Self.countLargeFiles(root)
        }
    }

    @Test func measureRealRoot() async throws {
        let root = try #require(Self.realRoot, "set MACOS_CLEAN_BENCH_ROOT to time a real folder")
        await Self.time("measure \(root.path)") {
            let result = SizeCalculator.measure(root)
            return "\(result.bytes.formatted(.byteCount(style: .file))), \(result.deniedPaths.count) denied"
        }
    }

    @Test func measureParallelSyntheticTree() async {
        let root = Self.synthetic.root
        await Self.time("measureParallel synthetic 100k files") {
            "\(await SizeCalculator.measureParallel(root).bytes) bytes"
        }
    }

    @Test func measureParallelRealRoot() async throws {
        let root = try #require(Self.realRoot, "set MACOS_CLEAN_BENCH_ROOT to time a real folder")
        await Self.time("measureParallel \(root.path)") {
            let result = await SizeCalculator.measureParallel(root)
            return "\(result.bytes.formatted(.byteCount(style: .file))), \(result.deniedPaths.count) denied"
        }
    }

    @Test func listRealRoot() async throws {
        let root = try #require(Self.realRoot, "set MACOS_CLEAN_BENCH_ROOT to time a real folder")
        await Self.time("list \(root.path)") {
            "\(await CategoryScanner().list(root).entries.count) entries"
        }
    }

    @Test func largeFilesRealRoot() async throws {
        let root = try #require(Self.realRoot, "set MACOS_CLEAN_BENCH_ROOT to time a real folder")
        await Self.time("large files \(root.path)") {
            await Self.countLargeFiles(root)
        }
    }

    static func countLargeFiles(_ root: URL) async -> String {
        var found = 0
        var scanned = 0
        for await event in LargeFileScanner(root: root, minimumBytes: 1_000_000, maxDepth: 12).scan() {
            switch event {
            case .found(let batch): found += batch.count
            case .progress(let count): scanned = count
            case .denied, .finished: break
            }
        }
        return "\(found) found / \(scanned) scanned"
    }
}
