import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @State private var access = Access.readOnly
    @State private var copied = false
    private enum Access: String, CaseIterable { case readOnly = "Read only", recovery = "Recovery actions", permanent = "Permanent deletion" }
    private var executable: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bleach").path
    }
    private var codexCommand: String {
        (["codex", "mcp", "add", "bleach", "--", executable] + arguments).map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
    private var arguments: [String] {
        ["mcp"] + (access == .readOnly ? [] : ["--allow-mutations"]) + (access == .permanent ? ["--allow-permanent-delete"] : [])
    }
    private var claudeConfig: String {
        let value = ["mcpServers": ["bleach": ["command": executable, "args": arguments] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
    }
    var body: some View {
        Section("MCP · connect your agent") {
            Text("Bleach provides a local stdio server for scans, APFS-aware analysis, exact previews, recovery and system statistics. No account or network service.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Configuration access", selection: $access) { ForEach(Access.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if access != .readOnly {
                Text(access == .permanent ? "This configuration exposes irreversible deletion tools. Require your agent to ask before each exact selection." : "This configuration allows approved files to move to Recovery and be restored. Moving them frees no space.")
                    .font(.caption).foregroundStyle(access == .permanent ? .red : .secondary)
            }
            HStack {
                Button("Copy Claude Config") { copy(claudeConfig) }
                Button("Copy Codex Command") { copy(codexCommand) }
                if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
            }.controlSize(.small)
            Text("Copying a configuration changes no agent settings. Read-only access is the default.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: access) { _, _ in copied = false }
    }
}
