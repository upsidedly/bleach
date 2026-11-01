import BleachCore
import SwiftUI

struct SharingReviewSheet: View {
    @Bindable var model: AppModel
    let plan: CleanupPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Share duplicate storage").font(.title2.weight(.semibold))
                Text("\(Display.items(plan.candidates.count)) · \(Display.bytes(plan.storage.privateBytes)) private in selected copies")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Both paths and file contents stay. Bleach creates independent APFS clones and verifies them before permanently erasing the originals from this specific Recovery batch.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(plan.candidates) { candidate in
                VStack(alignment: .leading, spacing: 5) {
                    Text(Display.path(candidate.path, home: model.home)).font(.subheadline.weight(.medium)).textSelection(.enabled)
                    if let proof = candidate.duplicateProof {
                        Text("Shares data with \(Display.path(proof.keeperPath, home: model.home))").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 7)
            }.listStyle(.inset)
            Text("Later edits affect only the edited copy. If verification fails, originals stay in Recovery. Private allocation is an estimate, not a promise of an equal increase in available space.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.sharingRequest = nil }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) { model.shareStorage() } label: { PrimaryButtonLabel(title: "Share Storage") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-share-storage")
            }
        }.padding(26).frame(width: 560, height: 470)
    }
}
