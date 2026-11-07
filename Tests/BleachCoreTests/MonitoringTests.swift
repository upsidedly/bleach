import Darwin
import BleachFS
import Foundation
import Testing
@testable import BleachCore

@Suite struct MonitoringTests {
    @Test func cpuCountersUseNanosecondsOnAppleSilicon() throws {
        var before = BLProcessSample(), after = BLProcessSample()
        var first = rusage(), last = rusage()
        #expect(bl_process_sample(getpid(), &before) == 0)
        #expect(getrusage(RUSAGE_SELF, &first) == 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.06
        var iterations = 0
        while ProcessInfo.processInfo.systemUptime < deadline { iterations &+= 1 }
        #expect(iterations > 0)
        #expect(getrusage(RUSAGE_SELF, &last) == 0)
        #expect(bl_process_sample(getpid(), &after) == 0)
        func nanos(_ value: rusage) -> Double {
            Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1_000_000_000 + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) * 1000
        }
        let expected = nanos(last) - nanos(first)
        let measured = Double(after.cpu_nanoseconds - before.cpu_nanoseconds)
        #expect(abs(measured - expected) <= max(5_000_000, expected * 0.2))
    }
    @Test func currentProcessHasStableIdentityAndMemory() async throws {
        let monitor = ProcessMonitor()
        let first = try await monitor.sample()
        let before = try #require(first.first { $0.pid == getpid() })
        #expect(before.started > 0 && before.memoryBytes > 0)
        #expect(before.cpuPercent == nil)
        try await Task.sleep(for: .milliseconds(30))
        let second = try await monitor.sample()
        let after = try #require(second.first { $0.pid == getpid() })
        #expect(before.id == after.id)
        #expect(after.cpuPercent.map { $0.isFinite && $0 >= 0 } == true)
        #expect(Set(second.map(\.id)).count == second.count)
        #expect(second.count <= 8192)
    }
    @Test @MainActor func ownProcessCannotBeQuit() {
        let process = ProcessUsage(pid: getpid(), started: 0, name: "test", memoryBytes: 0, cpuPercent: nil)
        #expect(ProcessControl.application(for: process) == nil)
        #expect(throws: (any Error).self) { try ProcessControl.quit(process) }
    }
}
