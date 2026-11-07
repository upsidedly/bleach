import BleachCore
import SwiftUI

struct DiskSpaceMeter: View {
    let total: Int64
    let available: Int64
    var compact = false
    private var known: Bool { total > 0 && available >= 0 }
    private var free: Int64 { min(total, max(0, available)) }
    private var usedFraction: Double { known ? 1 - Double(free) / Double(total) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 13) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(known ? Display.bytes(free) : "Unavailable")
                    .font(compact ? .title3.weight(.semibold) : .largeTitle.weight(.semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                if known { Text("free").font(compact ? .caption : .subheadline).foregroundStyle(.secondary) }
            }
            if known {
                GeometryReader { geometry in
                    let count = max(16, min(72, Int(geometry.size.width / 6)))
                    let occupied = usedFraction == 0 ? 0 : free == 0 ? count : min(count - 1, max(1, Int((usedFraction * Double(count)).rounded())))
                    HStack(spacing: 2) {
                        ForEach(0..<count, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(index < occupied ? usedColor(Double(index) / Double(count)) : Color.primary.opacity(0.12))
                        }
                    }
                }.frame(height: compact ? 13 : 20).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk space")
        .accessibilityValue(known ? "\(Display.bytes(free)) free, \(Display.bytes(total - free)) used of \(Display.bytes(total))" : "Unavailable")
        .help(known ? "\(Display.bytes(total - free)) used of \(Display.bytes(total)). Measured volume space; cleanup estimates are separate." : "macOS did not return disk capacity")
    }

    private func usedColor(_ position: Double) -> Color {
        if position < 0.55 { return .red }
        if position < 0.72 { return .yellow }
        return .orange
    }
}

struct CleanupKindIcon: View {
    let kind: CleanupKind
    var size: CGFloat = 19
    var body: some View {
        Image(systemName: kind.symbol).font(.system(size: size, weight: .medium))
            .foregroundStyle(kind.color).frame(width: size + 5, height: size + 5)
            .accessibilityHidden(true)
    }
}

extension CleanupKind {
    var color: Color {
        switch self {
        case .appCaches: .teal
        case .browsers: .cyan
        case .logs: .gray
        case .xcode: .blue
        case .packages: .orange
        case .compiler: .indigo
        case .builds: .purple
        case .dependencies: .brown
        case .installers: .green
        case .applications: .mint
        case .appData: .pink
        case .duplicates: .yellow
        case .archives: .red
        }
    }
}

struct GroupedCleanupList: View {
    @Bindable var model: AppModel
    let candidates: [CleanupCandidate]
    @State private var expanded: Set<CleanupKind> = []

    private var kinds: [CleanupKind] {
        CleanupKind.allCases.filter { kind in candidates.contains { $0.kind == kind } }
            .sorted { total($0) > total($1) }
    }
    private func items(_ kind: CleanupKind) -> [CleanupCandidate] { candidates.filter { $0.kind == kind } }
    private func total(_ kind: CleanupKind) -> Int64 { items(kind).reduce(0) { $0 + $1.privateBytes } }

    var body: some View {
        List {
            ForEach(kinds) { kind in
                let values = items(kind)
                let selectable = values.filter { $0.recommendation != .blocked }
                let selected = selectable.filter { model.selectedPaths.contains($0.path) }.count
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(kind) }, set: { if $0 { expanded.insert(kind) } else { expanded.remove(kind) } })) {
                    ForEach(values) { item in
                        HStack(spacing: 10) {
                            Toggle("Select \(item.title)", isOn: Binding(get: { model.selectedPaths.contains(item.path) }, set: { model.toggle(item, selected: $0) }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(item.recommendation == .blocked || model.isBusy)
                            Button { model.focusedCandidate = item.path; model.showInspector = true } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(item.blockedReason ?? "\(item.recommendation.label) · changed \(Display.age(item.snapshot.newestModification).lowercased())")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(Display.path(item.path, home: model.home))
                            Text(Display.bytes(item.privateBytes)).font(.subheadline).monospacedDigit()
                        }.padding(.vertical, 5)
                            .contextMenu {
                                Button("Reveal in Finder") { model.reveal(item.path) }
                                Button("Exclude from Cleanup") { model.protect(item.path) }.disabled(model.isBusy)
                            }
                    }
                } label: {
                    HStack(spacing: 11) {
                        let bindings = selectable.map { item in
                            Binding(get: { model.selectedPaths.contains(item.path) }, set: { model.toggle(item, selected: $0) })
                        }
                        Toggle(sources: bindings, isOn: \.self) {
                            Text("Select \(kind.title)")
                        }.labelsHidden().toggleStyle(.checkbox).disabled(selectable.isEmpty || model.isBusy)
                        CleanupKindIcon(kind: kind)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title).font(.subheadline.weight(.medium))
                            Text("\(Display.items(values.count)) · \(selected) selected\(values.count > selectable.count ? " · \(values.count - selectable.count) in use" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 5)
                        Text(Display.bytes(total(kind))).font(.subheadline).monospacedDigit()
                    }.padding(.vertical, 7)
                        .alignmentGuide(.firstTextBaseline) { dimensions in
                            (dimensions[.firstTextBaseline] + dimensions[.lastTextBaseline]) / 2
                        }
                }
            }
        }.listStyle(.inset).accessibilityIdentifier("cleanup-groups")
    }
}
