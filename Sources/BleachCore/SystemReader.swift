import AppKit
import Darwin
import Foundation
import IOKit

public enum RunningApplications {
    @MainActor public static func snapshot() -> [RunningOwner] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let path = app.bundleURL?.standardizedFileURL.path else { return nil }
            return RunningOwner(bundleID: id, applicationPath: path)
        }
    }
}

public enum SystemReader {
    /// Driver-reported whole-GPU utilization; keys vary by driver. Absence is
    /// unavailable, never an invented zero. No privileged IOReport/private API.
    private static func gpuReading() -> (percent: Double?, allocated: Int64?, inUse: Int64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return (nil, nil, nil) }
        defer { IOObjectRelease(iterator) }
        var samples: [Double] = []
        var allocated: [Int64] = [], inUse: [Int64] = []
        for _ in 0..<16 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                if let number = value["Device Utilization %"] as? NSNumber {
                    let percent = number.doubleValue
                    if percent.isFinite && (0...100).contains(percent) { samples.append(percent) }
                }
                if let number = value["Alloc system memory"] as? NSNumber, number.int64Value >= 0 { allocated.append(number.int64Value) }
                if let number = value["In use system memory"] as? NSNumber, number.int64Value >= 0 { inUse.append(number.int64Value) }
            }
        }
        return (samples.max(), allocated.max(), inUse.max())
    }
    public static func disk(at url: URL) -> (total: Int64, available: Int64) {
        var values = statvfs()
        guard statvfs(url.path, &values) == 0 else { return (-1, -1) }
        return (Int64(values.f_blocks) * Int64(values.f_frsize), Int64(values.f_bavail) * Int64(values.f_frsize))
    }

    private static func cpuTicks() -> (active: UInt64, total: UInt64)? {
        let host = mach_host_self()
        defer { _ = mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    public static func sample(at url: URL) async throws -> SystemSnapshot {
        let first = cpuTicks()
        try await Task.sleep(for: .milliseconds(200))
        let second = cpuTicks()
        var cpu: Double?
        if let first, let second, second.total > first.total, second.active >= first.active {
            cpu = min(100, 100 * Double(second.active - first.active) / Double(second.total - first.total))
        }
        let host = mach_host_self()
        defer { _ = mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw BleachError("macOS memory statistics are unavailable") }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { throw BleachError("macOS page size is unavailable") }
        let total = ProcessInfo.processInfo.physicalMemory
        let reclaimable = (UInt64(info.free_count) + UInt64(info.inactive_count)) * UInt64(pageSize)
        var swap = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &length, nil, 0) == 0
        let disk = disk(at: url)
        let gpu = gpuReading()
        return SystemSnapshot(sampledAt: Date(), volumePath: url.path, diskTotal: disk.total, diskAvailable: disk.available,
            memoryTotal: total, memoryUsed: total - min(total, reclaimable),
            memoryCompressed: UInt64(info.compressor_page_count) * UInt64(pageSize), swapUsed: swapOK ? swap.xsu_used : nil,
            cpuPercent: cpu, gpuPercent: gpu.percent, gpuMemoryAllocated: gpu.allocated, gpuMemoryInUse: gpu.inUse, processorCount: ProcessInfo.processInfo.processorCount,
            uptime: ProcessInfo.processInfo.systemUptime, hostname: ProcessInfo.processInfo.hostName)
    }
}
