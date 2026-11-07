import AppKit
import BleachFS
import Darwin
import Foundation

public struct ProcessUsage: Codable, Sendable, Identifiable {
    public var pid: Int32
    public var started: UInt64
    public var name: String
    public var memoryBytes: UInt64
    public var cpuPercent: Double?
    public var parentPID: Int32 = 0
    public var processCount: Int = 1
    public var id: String { "\(pid)-\(started)" }
}

/// Bounded, user-owned process metrics. No arguments, environment or file contents.
public actor ProcessMonitor {
    private var previous: [Int32: (started: UInt64, cpu: UInt64)] = [:]
    private var previousTime: Double?
    public init() {}

    public func sample() throws -> [ProcessUsage] {
        var raw = [BLProcessSample](repeating: BLProcessSample(), count: 8192)
        let count = bl_process_samples(&raw, raw.count)
        guard count >= 0 else { throw BleachError("macOS process statistics are unavailable") }
        let now = ProcessInfo.processInfo.systemUptime
        var next: [Int32: (started: UInt64, cpu: UInt64)] = [:]
        let result = raw.prefix(Int(count)).map { value in
            next[value.pid] = (value.started, value.cpu_nanoseconds)
            var name = value.name
            let title = withUnsafeBytes(of: &name) { data in
                String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            }
            let old = previous[value.pid]
            let cpu = previousTime.flatMap { time -> Double? in
                guard let old, old.started == value.started, value.cpu_nanoseconds >= old.cpu, now > time else { return nil }
                return 100 * Double(value.cpu_nanoseconds - old.cpu) / ((now - time) * 1_000_000_000)
            }
            return ProcessUsage(pid: value.pid, started: value.started, name: title, memoryBytes: value.footprint, cpuPercent: cpu, parentPID: value.parent_pid)
        }
        previous = next; previousTime = now
        return result
    }
}

public enum ProcessControl {
    /// Group visible process families under their real regular application.
    /// These are summed footprints, not a promise of immediately free RAM.
    @MainActor public static func groupedApplications(_ processes: [ProcessUsage]) -> [ProcessUsage] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let names = Dictionary(apps.map { ($0.processIdentifier, $0.localizedName ?? "Application") }, uniquingKeysWith: { first, _ in first })
        var groups: [Int32: [ProcessUsage]] = [:]
        for process in processes {
            var pid = process.pid
            var visited: Set<Int32> = []
            for _ in 0..<32 {
                guard pid > 1, visited.insert(pid).inserted, let parent = byPID[pid] else { break }
                if names[pid] != nil { groups[pid, default: []].append(process); break }
                pid = parent.parentPID
            }
        }
        return groups.compactMap { pid, members in
            guard var root = byPID[pid] else { return nil }
            root.name = names[pid] ?? root.name
            root.memoryBytes = members.reduce(0) { sum, member in
                let result = sum.addingReportingOverflow(member.memoryBytes)
                return result.overflow ? UInt64.max : result.partialValue
            }
            let knownCPU = members.compactMap(\.cpuPercent)
            root.cpuPercent = knownCPU.isEmpty ? nil : knownCPU.reduce(0, +)
            root.processCount = members.count
            return root
        }
    }
    @MainActor public static func application(for process: ProcessUsage) -> NSRunningApplication? {
        var current = BLProcessSample()
        guard process.pid != getpid(), bl_process_sample(process.pid, &current) == 0, current.started == process.started,
              let app = NSRunningApplication(processIdentifier: process.pid), app.activationPolicy == .regular,
              let bundle = app.bundleIdentifier,
              !["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver", "dev.upsided.bleach"].contains(bundle.lowercased()) else { return nil }
        return app
    }
    @MainActor public static func quit(_ process: ProcessUsage, force: Bool = false) throws {
        guard let app = application(for: process) else { throw BleachError("This process changed, exited or is protected. Refresh the list.") }
        let accepted = force ? app.forceTerminate() : app.terminate()
        guard accepted else { throw BleachError("macOS did not accept the quit request for \(process.name).") }
    }
}
