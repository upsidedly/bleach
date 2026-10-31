import BleachCore
import SwiftUI

struct CleanupView: View {
    @Bindable var model: AppModel
    @State private var showIssues = false

    var body: some View {
        VStack(spacing: 0) {
            if let batch = model.lastBatch, batch.movedCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").accessibilityHidden(true)
                    Text("\(Display.items(batch.movedCount)) moved to recovery").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Undo") { model.restore(batch) }.disabled(model.isBusy)
                    Button("View") { model.destination = .recovery }.disabled(model.isBusy)
                }.padding(.horizontal, 23).padding(.vertical, 12).background(.quaternary.opacity(0.4))
            }
            if let plan = model.plan {
                if plan.candidates.isEmpty {
                    EmptyState(symbol: "checkmark.circle", title: emptyTitle,
                        message: emptyMessage) {
                        Button("Scan Again") { model.scan() }.disabled(model.isBusy)
                        Button("Find More Space") { model.findMoreSpace() }.disabled(model.isBusy)
                    }
                    issuesButton(plan)
                } else {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Display.bytes(model.selectedBytes)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("selected").font(.subheadline.weight(.medium))
                                Text("\(Display.items(model.selectedCandidates.count)) · \(Display.duration(plan.duration))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if model.discovery != nil {
                            Text("\(Display.bytes(model.discoveredBytes)) found with Find More Space · \(Display.items(model.discoveredCandidates.count)) to review")
                                .font(.caption).foregroundStyle(.secondary)
                            if let result = model.discovery, result.installedInstallers > 0 {
                                Text(result.installedInstallers == 1 ? "1 installer matches an app already installed" : "\(result.installedInstallers) installers match apps already installed")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            Picker("Show", selection: $model.filter) {
                                ForEach(CandidateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 310)
                            Spacer(minLength: 0)
                            Menu {
                                Button("All Categories") { model.category = nil }
                                ForEach(CleanupCategory.allCases.filter { category in plan.candidates.contains { $0.category == category } }) { category in
                                    Button(category.title) { model.category = category }
                                }
                            } label: { Image(systemName: model.category == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                                .menuStyle(.borderlessButton).frame(width: 22)
                                .accessibilityLabel("Filter category").help(model.category?.title ?? "Filter category")
                        }
                        HStack {
                            Button("Select Suggested") { model.selectedPaths = Set(plan.suggested.map(\.path)) }.buttonStyle(.borderless)
                            if !model.selectedPaths.isEmpty { Button("Clear") { model.selectedPaths = [] }.buttonStyle(.borderless).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Find More Space") { model.findMoreSpace() }
                                .buttonStyle(.borderless).disabled(model.isBusy)
                                .help("Discover project artifacts, expanded ZIPs and installers matching apps already installed")
                                .accessibilityIdentifier("find-more-space")
                            issuesButton(plan)
                        }.font(.caption)
                    }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 15)
                    CandidateTable(model: model, candidates: model.visibleCandidates)
                        .overlay {
                            if model.visibleCandidates.isEmpty { ContentUnavailableView.search(text: model.search) }
                        }
                        .searchable(text: $model.search, placement: .toolbar, prompt: "Find an item")
                    SelectionBar(model: model)
                }
            } else {
                EmptyState(symbol: "sparkles", title: "A little more room.",
                    message: "Find old caches, logs, installers and build artifacts. Review each item, then keep a way back.") {
                    VStack(spacing: 14) {
                        Button("Scan Your Mac") { model.scan() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.return, modifiers: [])
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("scan-mac")
                        Text("Scanning changes nothing.").font(.caption).foregroundStyle(.secondary)
                        Button("Find More Space") { model.findMoreSpace() }.buttonStyle(.borderless).disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if model.lastBatch?.items.contains(where: { $0.state == .restored }) == true { return "Cleanup undone" }
        return model.lastBatch == nil ? "No candidates found" : "Nothing else to review"
    }
    private var emptyMessage: String {
        if model.lastBatch?.items.contains(where: { $0.state == .restored }) == true {
            return "Your files are back in their original locations. Scan again to refresh this review."
        }
        return model.lastBatch == nil ? "No eligible files were found in these locations. Find More Space checks project artifacts and expanded ZIP archives." : "Your selected files are in Recovery. Restore them there, or delete the batch to free disk space."
    }

    @ViewBuilder private func issuesButton(_ plan: CleanupPlan) -> some View {
        if !plan.issues.isEmpty {
            Button("\(plan.issues.count) skipped") { showIssues = true }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .popover(isPresented: $showIssues) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Skipped locations").font(.headline)
                        Text("Unreadable or protected locations do not become cleanup targets.").font(.subheadline).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(plan.issues) { issue in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(Display.path(issue.path, home: model.home)).font(.caption.monospaced()).textSelection(.enabled)
                                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxHeight: 340)
                    }.padding(20).frame(width: 400)
                }
        }
    }
}

struct CandidateTable: View {
    @Bindable var model: AppModel
    let candidates: [CleanupCandidate]
    var body: some View {
        Table(candidates, selection: $model.focusedCandidate, sortOrder: $model.sortOrder) {
            TableColumn("") { candidate in
                Toggle("Select \(candidate.title)", isOn: Binding(get: { model.activeSelection.contains(candidate.path) },
                                                               set: { model.toggle(candidate, selected: $0) }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(candidate.recommendation == .blocked || model.isBusy)
                    .help(candidate.blockedReason ?? "Include in cleanup")
            }.width(26)
            TableColumn("Item", value: \.title) { candidate in
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(candidate.category.title + " · " + candidate.recommendation.label).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 7)
                    .contextMenu {
                        Button("Reveal in Finder", systemImage: "folder") { model.reveal(candidate.path) }
                        Button("Exclude from Cleanup", systemImage: "hand.raised") { model.protect(candidate.path) }.disabled(model.isBusy)
                    }
            }.width(min: 140, ideal: 240)
            TableColumn("Size", value: \.allocatedBytes) { candidate in
                Text(Display.bytes(candidate.allocatedBytes)).monospacedDigit().font(.subheadline)
            }.width(min: 72, ideal: 82, max: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityIdentifier("cleanup-items")
    }
}

struct CandidateInspector: View {
    @Bindable var model: AppModel
    var body: some View {
        if let candidate = model.inspected {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: candidate.category.symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(candidate.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(Display.path(candidate.path, home: model.home)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(nil)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(candidate.blockedReason ?? candidate.recommendation.label).font(.subheadline.weight(.semibold))
                        Text(candidate.reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("What changes").font(.subheadline.weight(.semibold))
                        Text(candidate.consequence).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 11) {
                        GridRow { Text("Allocated").foregroundStyle(.secondary); Text(Display.bytes(candidate.allocatedBytes)).monospacedDigit() }
                        GridRow { Text("Logical").foregroundStyle(.secondary); Text(Display.bytes(candidate.snapshot.logicalBytes)).monospacedDigit() }
                        GridRow { Text("Files").foregroundStyle(.secondary); Text(candidate.snapshot.fileCount.formatted()).monospacedDigit() }
                        GridRow { Text("Changed").foregroundStyle(.secondary); Text(Display.age(candidate.snapshot.newestModification)) }
                    }.font(.caption)
                    if let proof = candidate.duplicateProof {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Copy kept", systemImage: "checkmark").font(.subheadline.weight(.medium))
                            Text(Display.path(proof.keeperPath, home: model.home)).font(.caption.monospaced()).textSelection(.enabled)
                            DisclosureGroup("Content verification") {
                                Text("Full SHA-256\n\(proof.sha256)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 5)
                            }.font(.caption)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Reveal in Finder", systemImage: "folder") { model.reveal(candidate.path) }
                        Button("Exclude from Cleanup", systemImage: "hand.raised") { model.protect(candidate.path) }.disabled(model.isBusy)
                    }.buttonStyle(.borderless).font(.subheadline)
                    Text("Allocation is an estimate. APFS clones, hard links and snapshots can share disk space.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(21).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 11) {
                Image(systemName: "info.circle").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true)
                Text("Select an item").font(.subheadline.weight(.medium))
                Text("See its location and what removing it changes.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ReviewSheet: View {
    @Bindable var model: AppModel
    let plan: CleanupPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Move to recovery").font(.title2.weight(.semibold))
                    Text("\(Display.items(plan.candidates.count)) · \(Display.bytes(plan.totalBytes)) allocated").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("These files will leave their current locations. Restore them from Recovery, or permanently delete the batch there to free disk space.")
                .font(.body).foregroundStyle(.secondary)
            List(plan.candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.title).font(.subheadline.weight(.medium))
                        Text(Display.path(candidate.path, home: model.home)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(Display.bytes(candidate.allocatedBytes)).font(.subheadline).monospacedDigit()
                }.padding(.vertical, 5)
            }.listStyle(.inset).frame(minHeight: 140, idealHeight: 240, maxHeight: 320)
            Text("Bleach checks these files again before moving them. If an app recreates a path, restore keeps both copies and asks you to resolve it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.review = nil }.keyboardShortcut(.escape, modifiers: [])
                Button("Move to Recovery") { model.applyReview() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-move")
            }
        }.padding(26).frame(width: 520)
    }
}
