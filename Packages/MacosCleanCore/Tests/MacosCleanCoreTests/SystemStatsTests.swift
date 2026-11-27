import Foundation
import Testing
@testable import MacosCleanCore

@Suite("System stats")
struct SystemStatsTests {
    @Test func cpuUsageIsBusyShareOfElapsedTicks() throws {
        let earlier = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let later = CPUTicks(user: 160, system: 70, idle: 1_000, nice: 20)
        // busy 60 + 20 + 20 = 100, idle 150 → 100 / 250.
        #expect(try #require(later.usage(since: earlier)) == 0.4)
    }

    @Test func cpuUsageIsNilWhenNothingElapsedOrCountersWentBack() {
        let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        #expect(ticks.usage(since: ticks) == nil)
        #expect(CPUTicks(user: 5, system: 10, idle: 10, nice: 0).usage(since: ticks) == nil)
    }

    @Test func samplerReportsRealValuesAndCPUFromTheSecondSample() {
        var sampler = SystemSampler()
        let first = sampler.sample()
        #expect(first.cpuUsage == nil)
        #expect(first.memoryTotal > 0)
        #expect(first.memoryUsed > 0 && first.memoryUsed <= first.memoryTotal)
        #expect(first.diskTotal > 0 && first.diskAvailable <= first.diskTotal)
        // Burn a little CPU so ticks advance.
        var sink = 0
        for value in 0..<2_000_000 { sink &+= value }
        #expect(sink != 1)
        let second = sampler.sample()
        if let cpu = second.cpuUsage { #expect((0...1).contains(cpu)) }
    }

    @Test func versionsCompareNumerically() throws {
        let v = { (text: String) in try #require(AppVersion(text)) }
        #expect(try v("1.10.0") > v("1.9.3"))
        #expect(try v("v1.2") == v("1.2.0"))
        #expect(try v("2.0.0-beta.1") == v("2.0.0"))
        #expect(try v("1.0.0") < v("1.0.1"))
        #expect(try v("v1.0.0").description == "1.0.0")
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
    }
}
