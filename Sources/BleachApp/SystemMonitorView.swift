import AppKit
import BleachCore
import Charts
import SwiftUI

struct SystemView: View {
    @Bindable var model: AppModel
    @State private var showAllProcesses = false
    @State private var processSelection: String?
    @State private var query = ""
    @State private var samples: [SystemSnapshot] = []
    private var metric: ResourceMetric { model.resourceMetric }
    private var processes: [ProcessUsage] {
        (showAllProcesses && metric != .gpu ? model.processes : model.appProcesses).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
            .sorted {
                if metric != .cpu { return $0.memoryBytes == $1.memoryBytes ? $0.pid < $1.pid : $0.memoryBytes > $1.memoryBytes }
                return $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
            }
    }
    private var selected: ProcessUsage? { (showAllProcesses && metric != .gpu ? model.processes : model.appProcesses).first { $0.id == processSelection } }
    var body: some View {
        VStack(spacing: 0) {
            if let sample = model.system {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(sample.hostname).font(.title2.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text("Up \(Int(sample.uptime / 3600))h").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 22) {
                        resource(.memory, value: 100 * Double(sample.memoryUsed) / Double(max(1, sample.memoryTotal)), detail: "\(Display.bytes(Int64(sample.memoryUsed))) of \(Display.bytes(Int64(sample.memoryTotal)))")
                        Divider()
                        resource(.cpu, value: sample.cpuPercent, detail: "\(sample.processorCount) cores")
                        Divider()
                        resource(.gpu, value: sample.gpuPercent, detail: sample.gpuMemoryAllocated.map { "\(Display.bytes($0)) driver allocated" } ?? (sample.gpuPercent == nil ? "Driver data unavailable" : "Driver-reported usage"))
                    }.frame(height: 95)
                    if samples.count > 1 {
                        Chart(samples, id: \.sampledAt) { point in
                            if let value = metricValue(point) {
                                AreaMark(x: .value("Time", point.sampledAt), y: .value(metric.rawValue, value)).foregroundStyle(Color.primary.opacity(0.04))
                                LineMark(x: .value("Time", point.sampledAt), y: .value(metric.rawValue, value)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.2))
                            }
                        }.chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 38)
                            .accessibilityLabel("Recent \(metric.rawValue) utilization").accessibilityValue("\(samples.count) samples")
                    }
                    HStack {
                        Text("\(Display.bytes(Int64(sample.memoryCompressed))) compressed")
                        Spacer()
                        Text(sample.swapUsed.map { "\(Display.bytes(Int64($0))) swap" } ?? "Swap unavailable")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            Divider()
            HStack {
                Picker("View", selection: $showAllProcesses) { Text("Apps").tag(false); Text("All Processes").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190).disabled(metric == .gpu)
                Spacer()
                Picker("Resource", selection: $model.resourceMetric) { ForEach(ResourceMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }.padding(.horizontal, 24).padding(.top, 17).padding(.bottom, 12)
            if metric == .gpu {
                if let used = model.system?.gpuMemoryInUse {
                    Text("\(Display.bytes(used)) GPU driver memory in use. On Apple silicon, GPU allocations share system memory.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 5)
                }
                Text("Quit an app to release its GPU work and allocations. Apps are listed by memory footprint; per-app GPU percentages are unavailable.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 10)
            }
            if let issue = model.processIssue { Text(issue).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24) }
            Table(processes, selection: $processSelection) {
                TableColumn("Process") { process in
                    HStack(spacing: 9) {
                        Group {
                            if let icon = model.appIcons[process.pid] { Image(nsImage: icon).resizable().scaledToFit() }
                            else { Image(systemName: "app").foregroundStyle(.secondary) }
                        }.frame(width: 22, height: 22).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(process.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(process.processCount > 1 ? "\(process.processCount) visible processes" : "PID \(process.pid)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }.width(min: 140, ideal: 250)
                TableColumn("Memory") { process in Text(Display.bytes(Int64(clamping: process.memoryBytes))).font(.subheadline).monospacedDigit() }.width(min: 75, ideal: 90)
                TableColumn("CPU") { process in Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—").font(.subheadline).monospacedDigit() }.width(70)
            }.tableStyle(.inset(alternatesRowBackgrounds: true)).searchable(text: $query, placement: .toolbar, prompt: "Find a process")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusMessage ?? "Select an app to quit and release its resources. Footprints include visible helpers.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let system = model.system { Text("Checked \(system.sampledAt.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 8)
                if let selected {
                    Button("Quit") { model.quit(selected) }.disabled(!model.canQuit(selected))
                    Menu {
                        Button("Force Quit…", role: .destructive) { model.quitRequest = selected }.disabled(!model.canQuit(selected))
                        if let app = ProcessControl.application(for: selected), let path = app.bundleURL?.path {
                            Button("Review Uninstall…") { model.destination = .applications; model.previewApp(path) }.disabled(model.isBusy)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Process actions")
                }
            }.padding(.horizontal, 24).padding(.vertical, 15).background(.bar)
        }.onChange(of: metric) { _, value in
            if value == .gpu { showAllProcesses = false }
        }.task {
            while !Task.isCancelled {
                await model.sampleSystem(); await model.sampleProcesses()
                guard !Task.isCancelled else { return }
                if let sample = model.system, sample.sampledAt != samples.last?.sampledAt { samples.append(sample) }
                if samples.count > 40 { samples.removeFirst() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func metricValue(_ sample: SystemSnapshot) -> Double? {
        switch metric {
        case .memory: 100 * Double(sample.memoryUsed) / Double(max(1, sample.memoryTotal))
        case .cpu: sample.cpuPercent
        case .gpu: sample.gpuPercent
        }
    }
    private func resource(_ kind: ResourceMetric, value: Double?, detail: String) -> some View {
        Button { model.resourceMetric = kind; showAllProcesses = false } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Label(kind.rawValue, systemImage: "chevron.down").font(.subheadline.weight(metric == kind ? .semibold : .regular))
                    Spacer(minLength: 5)
                    Text(value.map { "\(Int($0))%" } ?? "—").font(.title2.weight(.medium)).monospacedDigit()
                }
                ProgressView(value: min(100, max(0, value ?? 0)), total: 100).tint(.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .accessibilityLabel("Manage \(kind.rawValue)").accessibilityValue(value.map { "\(Int($0)) percent" } ?? "Unavailable")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.resourceMetric = kind; showAllProcesses = false }
            .help("Choose apps to quit and release their resources")
    }
}
