import Foundation

/// HTTP and compiled-code caches only. Never select a whole user-data profile,
/// service-worker storage, cookies, databases, downloads or offline documents.
enum ChromiumCaches {
    struct App {
        let id: String
        let folder: String
        let name: String
        var category: CleanupCategory = .caches
    }
    static let apps = [
        App(id: "com.hnc.Discord", folder: "discord", name: "Discord"),
        App(id: "com.tinyspeck.slackmacgap", folder: "Slack", name: "Slack"),
        App(id: "notion.id", folder: "Notion", name: "Notion"),
        App(id: "com.figma.Desktop", folder: "Figma", name: "Figma"),
        App(id: "com.t3tools.t3code", folder: "t3code-v2", name: "T3 Code"),
        App(id: "com.google.Chrome", folder: "Google/Chrome", name: "Chrome", category: .browsers),
        App(id: "company.thebrowser.Browser", folder: "Arc/User Data", name: "Arc", category: .browsers),
        App(id: "com.brave.Browser", folder: "BraveSoftware/Brave-Browser", name: "Brave", category: .browsers),
        App(id: "com.microsoft.edgemac", folder: "Microsoft Edge", name: "Edge", category: .browsers)
    ]
    static let cacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "ShaderCache"]
    static let archiveNames: Set<String> = ["component_crx_cache", "extensions_crx_cache"]
    static func updaterCache(_ context: ScanContext) -> String { context.homeURL("Library/Application Support/Google/GoogleUpdater/crx_cache").path }
    static func updaterExecutables(_ context: ScanContext) -> String { context.homeURL("Library/Google/GoogleUpdater").path }

    static func profile(_ parts: ArraySlice<String>) -> Bool {
        if parts.isEmpty { return true }
        if parts.count == 1, let name = parts.first {
            return name == "Default" || (name.hasPrefix("Profile ") && !name.dropFirst(8).isEmpty && name.dropFirst(8).allSatisfy(\.isNumber))
        }
        if parts.count == 2 {
            let pair = Array(parts)
            if pair[0] == "Partitions" { return !pair[1].isEmpty && !pair[1].hasPrefix(".") }
            if pair[0] == "DesktopProfile" { return pair[1].hasPrefix("v") && !pair[1].dropFirst().isEmpty && pair[1].dropFirst().allSatisfy(\.isNumber) }
        }
        return false
    }

    static func seeds(context: ScanContext, installed: [InstalledApp]) -> [CandidateSeed] {
        var seeds: [CandidateSeed] = []
        for definition in apps {
            guard let app = installed.first(where: { $0.bundleID == definition.id &&
                (context.home == Files.canonicalURL(FileManager.default.homeDirectoryForCurrentUser) || Files.pathIsWithin($0.path, context.homeURL("Applications").path)) }) else { continue }
            let root = context.homeURL("Library/Application Support/" + definition.folder)
            var profiles = [root]
            if let children = try? Files.children(root.path) {
                profiles += children.filter { profile([$0.lastPathComponent][...]) }
            }
            for container in ["Partitions", "DesktopProfile"] {
                if let children = try? Files.children(root.appendingPathComponent(container).path) {
                    profiles += children.filter { profile([container, $0.lastPathComponent][...]) }
                }
            }
            for directory in profiles {
                let names = definition.category == .browsers && directory.path == root.path ? cacheNames.union(archiveNames) : cacheNames
                for name in names.sorted() {
                    let path = directory.appendingPathComponent(name).path
                    guard Files.exists(path) else { continue }
                    let archive = archiveNames.contains(name)
                    let label = name == "component_crx_cache" ? "Component downloads" : name == "extensions_crx_cache" ? "Extension downloads" : name
                    seeds.append(CandidateSeed(path: path, title: "\(definition.name) · \(label)", category: definition.category, rule: .chromiumCache,
                        reason: archive ? "Downloaded component or extension packages; installed copies are separate." : "HTTP or compiled-code cache inside this installed app's profile.",
                        consequence: archive ? "The browser downloads these archives again. Installed components, extensions and profile data stay." : "The app downloads or recompiles cached content. Cookies, sessions, offline storage and documents stay.",
                        owner: definition.id, application: app.path))
                }
            }
        }
        if let chrome = installed.first(where: { $0.bundleID == "com.google.Chrome" &&
            (context.home == Files.canonicalURL(FileManager.default.homeDirectoryForCurrentUser) || Files.pathIsWithin($0.path, context.homeURL("Applications").path)) }), Files.exists(updaterCache(context)) {
            seeds.append(CandidateSeed(path: updaterCache(context), title: "Google update downloads", category: .caches, rule: .chromiumCache,
                reason: "Downloaded update payloads in Google's per-user archive cache.",
                consequence: "Google downloads these update archives again when needed. Installed apps and updater binaries stay.",
                owner: chrome.bundleID, application: chrome.path))
        }
        return seeds
    }

    static func matches(_ candidate: CleanupCandidate, context: ScanContext, restoring: Bool) -> Bool {
        guard let definition = apps.first(where: { $0.id == candidate.ownerBundleID }), let app = candidate.applicationPath else { return false }
        let appURL = URL(fileURLWithPath: app), parent = appURL.deletingLastPathComponent().path
        guard ["/Applications", context.homeURL("Applications").path].contains(parent), appURL.pathExtension == "app",
              restoring || CleanupPolicy.bundleID(at: app) == definition.id else { return false }
        if candidate.path == updaterCache(context) { return definition.id == "com.google.Chrome" }
        let root = context.homeURL("Library/Application Support/" + definition.folder).path
        guard candidate.path.hasPrefix(root + "/") else { return false }
        let parts = candidate.path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last else { return false }
        if archiveNames.contains(name) { return definition.category == .browsers && parts.count == 1 }
        guard cacheNames.contains(name) else { return false }
        return profile(parts.dropLast())
    }
}
