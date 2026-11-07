import Foundation

public enum CleanupLevel: String, CaseIterable, Sendable {
    case light = "Light", balanced = "Balanced", thorough = "Thorough", custom = "Custom"

    public func includes(_ item: CleanupCandidate) -> Bool {
        guard item.recommendation != .blocked else { return false }
        switch self {
        case .light:
            return item.recommendation == .suggested && (item.rule.isRebuildableCache || item.rule == .log) && item.rule != .xcodeDerivedData && item.rule != .clangModuleCache
        case .balanced: return item.recommendation == .suggested
        case .thorough:
            return item.recommendation == .suggested || (item.kind != .dependencies && [.projectArtifact, .customBuildOutput, .projectProcessingCache].contains(item.rule))
        case .custom: return false
        }
    }

    public var detail: String {
        switch self {
        case .light: "Suggested caches and old logs; keep compiler and Xcode build caches."
        case .balanced: "All suggested items. Review-only items stay unchecked."
        case .thorough: "Also select regenerable project output. Installers, inactive dependencies and personal data still need your choice."
        case .custom: "Your selection. In-use items remain protected."
        }
    }
}

public enum CleanupKind: String, CaseIterable, Sendable, Identifiable {
    case appCaches, browsers, logs, xcode, packages, compiler, builds, dependencies, installers, applications, appData, duplicates, archives
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .appCaches: "App caches"
        case .browsers: "Browser caches"
        case .logs: "Old logs"
        case .xcode: "Xcode build data"
        case .packages: "Package caches"
        case .compiler: "Compiler caches"
        case .builds: "Generated project output"
        case .dependencies: "Project dependencies"
        case .installers: "Installers"
        case .applications: "Applications"
        case .appData: "App data"
        case .duplicates: "Duplicates"
        case .archives: "Expanded archives"
        }
    }
    public var symbol: String {
        switch self {
        case .appCaches: "square.stack.3d.up"
        case .browsers: "globe"
        case .logs: "doc.text"
        case .xcode: "hammer"
        case .packages: "shippingbox"
        case .compiler: "cpu"
        case .builds: "gearshape.2"
        case .dependencies: "shippingbox.and.arrow.backward"
        case .installers: "arrow.down.circle"
        case .applications: "app"
        case .appData: "folder.badge.gearshape"
        case .duplicates: "square.on.square"
        case .archives: "doc.zipper"
        }
    }
}

extension CleanupCandidate {
    public var kind: CleanupKind {
        switch rule {
        case .xcodeDerivedData: return .xcode
        case .clangModuleCache: return .compiler
        case .npmCache, .pipCache, .gradleCache, .swiftPMCache, .npxCache, .packageDownloadCache: return .packages
        case .inactiveDependencies: return .dependencies
        case .projectArtifact where path.hasSuffix("/node_modules") || path.hasSuffix("/.venv"): return .dependencies
        default: break
        }
        switch category {
        case .caches: return .appCaches
        case .browsers: return .browsers
        case .logs: return .logs
        case .developer: return .compiler
        case .builds: return .builds
        case .installers: return .installers
        case .applications: return .applications
        case .appData: return .appData
        case .duplicates: return .duplicates
        case .archives: return .archives
        }
    }
}
