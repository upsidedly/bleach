import Darwin
import Foundation

struct CleanupPolicy {
    let context: ScanContext
    let preferences: Preferences

    func exclusionReason(_ path: String) -> String? {
        if Files.pathIsWithin(path, context.state.path) || Files.pathIsWithin(context.state.path, path) {
            return "Bleach recovery and settings are protected"
        }
        if preferences.excludes(path) { return "Excluded in Bleach settings" }
        return nil
    }

    func validate(_ candidate: CleanupCandidate) throws {
        let path = candidate.path
        guard path.hasPrefix("/"), Files.lexicalPath(path) == path,
              !path.contains("\0"), path != "/", path != context.home.path else {
            throw BleachError("Invalid cleanup path: \(Display.terminalSafe(path))")
        }
        guard Files.pathIsWithin(path, context.home.path) || candidate.rule == .application || (candidate.rule == .clangModuleCache && path == context.compilerCache?.path) else {
            throw BleachError("Cleanup path is outside this home: \(path)")
        }
        if let reason = exclusionReason(path) { throw BleachError("\(reason): \(path)") }
        try Files.ensureRealDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let stamp = try Files.stamp(path)
        guard stamp.kind == 1 || stamp.kind == 2, stamp.owner == getuid(), !stamp.dataless else {
            throw BleachError("Linked, cloud-only, special or foreign-owned target retained: \(path)")
        }
        guard ruleMatches(candidate) else { throw BleachError("Path does not match its cleanup rule: \(path)") }
        if candidate.rule == .inactiveDependencies { try ProjectReview.validate(candidate, policy: self) }
        if let busy = busyReason(candidate) { throw BleachError(busy + ": " + path) }
    }

    func ruleMatches(_ candidate: CleanupCandidate, restoring: Bool = false) -> Bool {
        let url = URL(fileURLWithPath: candidate.path)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let relative = candidate.path.hasPrefix(context.home.path + "/") ? String(candidate.path.dropFirst(context.home.path.count + 1)) : ""
        switch candidate.rule {
        case .userCache:
            return parent == context.homeURL("Library/Caches").path && !name.hasPrefix(".") && !isProtectedCache(name)
        case .log:
            let logs = context.homeURL("Library/Logs").path
            let diagnostics = context.homeURL("Library/Logs/DiagnosticReports").path
            return (parent == logs && name != "DiagnosticReports" && !name.hasPrefix(".")) || (parent == diagnostics && ["ips", "crash", "diag"].contains(url.pathExtension.lowercased()))
        case .xcodeDerivedData:
            return parent == context.homeURL("Library/Developer/Xcode/DerivedData").path && !name.hasPrefix(".")
        case .npmCache: return relative == ".npm/_cacache"
        case .pipCache: return relative == "Library/Caches/pip" || relative == ".cache/pip"
        case .gradleCache: return relative == ".gradle/caches"
        case .swiftPMCache: return relative == ".cache/org.swift.swiftpm"
        case .clangModuleCache: return candidate.path == context.compilerCache?.path
        case .npxCache: return relative == ".npm/_npx"
        case .packageDownloadCache:
            return CacheLocations.matches(candidate, context: context, restoring: restoring)
        case .chromiumCache:
            return ChromiumCaches.matches(candidate, context: context, restoring: restoring)
        case .projectProcessingCache:
            guard let project = ProjectOutputs.processingProject(for: url) else { return false }
            return Files.pathIsWithin(project.path, context.home.path) && !protectedUserPath(project.path)
        case .inactiveDependencies:
            guard Files.pathIsWithin(parent, context.home.path), !protectedUserPath(parent),
                  ["node_modules", ".venv", "venv"].contains(name), candidate.projectEvidence != nil else { return false }
            return restoring || (try? ProjectReview.recipe(url)) != nil
        case .customBuildOutput:
            if let project = ProjectOutputs.swiftProject(for: url, requireContents: !restoring) {
                return Files.pathIsWithin(project.path, context.home.path) && !protectedUserPath(project.path)
            }
            guard let project = candidate.outputProjectPath, Files.pathIsWithin(project, context.home.path),
                  Files.pathIsWithin(parent, project), !protectedUserPath(parent), !protectedUserPath(project),
                  ProjectOutputs.regular(URL(fileURLWithPath: project).appendingPathComponent("package.json")) else { return false }
            return restoring || ProjectOutputs.nextProject(for: url)?.path == project
        case .projectArtifact:
            guard Files.pathIsWithin(parent, context.home.path), !protectedUserPath(parent) else { return false }
            return Self.projectArtifactMatches(url)
        case .installer:
            return parent == context.homeURL("Downloads").path && ["dmg", "pkg", "xip"].contains(url.pathExtension.lowercased())
        case .application:
            guard parent == "/Applications" || parent == context.homeURL("Applications").path,
                  name.hasSuffix(".app"), let id = candidate.ownerBundleID, Self.validBundleID(id),
                  restoring || Self.bundleID(at: candidate.path) == id else { return false }
            return !id.hasPrefix("com.apple.")
        case .appRelatedData:
            guard let id = candidate.ownerBundleID, Self.validBundleID(id), !id.hasPrefix("com.apple."),
                  let app = candidate.applicationPath else { return false }
            let appParent = URL(fileURLWithPath: app).deletingLastPathComponent().path
            guard appParent == "/Applications" || appParent == context.homeURL("Applications").path else { return false }
            return ["Library/Caches/\(id)", "Library/Preferences/\(id).plist",
                    "Library/Saved Application State/\(id).savedState", "Library/Application Support/\(id)"].contains(relative)
        case .duplicate:
            return candidate.duplicateProof != nil && !protectedUserPath(candidate.path) && (restoring || (try? Files.stamp(candidate.path).kind) == 1)
        case .expandedArchive:
            guard let proof = candidate.archiveProof else { return false }
            return Files.pathIsWithin(candidate.path, context.home.path) && !protectedUserPath(candidate.path) &&
                url.pathExtension.lowercased() == "zip" && proof.expandedPath == url.deletingPathExtension().path &&
                !protectedUserPath(proof.expandedPath) && (restoring || (try? Files.stamp(candidate.path).kind) == 1)
        case .archivedInstaller:
            return candidate.installerProof != nil && Files.pathIsWithin(candidate.path, context.home.path) &&
                !protectedUserPath(candidate.path) && url.pathExtension.lowercased() == "zip" &&
                (restoring || (try? Files.stamp(candidate.path).kind) == 1)
        }
    }

    func busyReason(_ candidate: CleanupCandidate) -> String? {
        if candidate.rule == .projectProcessingCache, let project = ProjectOutputs.processingProject(for: URL(fileURLWithPath: candidate.path)) {
            do { try ProjectReview.requireIdle(project.path) }
            catch { return error.localizedDescription }
        }
        if candidate.rule.isRebuildableCache || candidate.rule == .customBuildOutput {
            do { try ProjectReview.requireIdle(candidate.path, includeWorkingDirectory: true) }
            catch { return error.localizedDescription }
        }
        if candidate.rule == .chromiumCache, candidate.path == ChromiumCaches.updaterCache(context) {
            do { try ProjectReview.requireIdle(ChromiumCaches.updaterExecutables(context)) }
            catch { return error.localizedDescription }
            if context.runningOwners.contains(where: { $0.bundleID.hasPrefix("com.google.GoogleUpdater") }) { return "Google Updater is running" }
        }
        let name = URL(fileURLWithPath: candidate.path).lastPathComponent
        let inferred = candidate.rule == .userCache || candidate.rule == .log ? name : candidate.ownerBundleID
        for owner in context.runningOwners {
            if candidate.rule == .application && owner.applicationPath == candidate.path { return "Quit the app before removing it" }
            if let id = candidate.ownerBundleID, id == owner.bundleID || owner.bundleID.hasPrefix(id + ".") { return "The owning app is running" }
            if let inferred, inferred == owner.bundleID || owner.bundleID.hasPrefix(inferred + ".") { return "The owning app is running" }
            if candidate.rule == .userCache {
                let aliases = ["Google": "com.google.", "Firefox": "org.mozilla.", "Microsoft": "com.microsoft.", "Homebrew": "org.homebrew."]
                if let prefix = aliases[name], owner.bundleID.hasPrefix(prefix) { return "An app using this cache is running" }
            }
            if candidate.rule == .xcodeDerivedData && owner.bundleID == "com.apple.dt.Xcode" { return "Xcode is running" }
        }
        return nil
    }

    func protectedUserPath(_ path: String) -> Bool {
        let protected = ["Library", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".config", ".codex", ".t3", ".claude", ".local", ".Trash"]
        if protected.contains(where: { Files.pathIsWithin(path, context.homeURL($0).path) }) { return true }
        let components = URL(fileURLWithPath: path).pathComponents
        return components.contains(where: { component in
            component == ".git" || component == "node_modules" || component == ".build" || component == ".venv" ||
            ["Dropbox", "OneDrive", "Google Drive", "iCloud Drive", "CloudStorage", "Mobile Documents", ".dropbox"].contains(component) ||
            component.hasPrefix("OneDrive - ") || component == ".env" || component.hasPrefix(".env.") ||
            ["id_rsa", "id_ed25519", "credentials"].contains(component) ||
            [".pem", ".p12", ".pfx", ".key"].contains(where: component.lowercased().hasSuffix) ||
            [".app", ".photolibrary", ".photoslibrary", ".bundle", ".framework", ".backupbundle", ".sparsebundle"].contains(where: component.lowercased().hasSuffix)
        })
    }

    func isProtectedCache(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("com.apple.") || ["cloudkit", "cloudkitmetadata", "clouddocs", "com.apple.bird", "metadata", "bleach", "uv", "pnpm", "bun", "yarn"].contains(name)
    }

    static func projectArtifactMatches(_ url: URL) -> Bool {
        let project = url.deletingLastPathComponent()
        func regularManifest(_ name: String) -> Bool {
            guard let stamp = try? Files.stamp(project.appendingPathComponent(name).path) else { return false }
            return stamp.kind == 1 && !stamp.dataless && stamp.size < 5_000_000
        }
        switch url.lastPathComponent {
        case "node_modules":
            guard regularManifest("package.json"), let data = try? Data(contentsOf: project.appendingPathComponent("package.json")) else { return false }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil
        case ".build": return regularManifest("Package.swift")
        case "target": return regularManifest("Cargo.toml")
        case ".next":
            guard regularManifest("package.json"), let data = try? Data(contentsOf: project.appendingPathComponent("package.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (json["dependencies"] as? [String: Any])?["next"] != nil || (json["devDependencies"] as? [String: Any])?["next"] != nil
        default: return false
        }
    }

    static func validBundleID(_ id: String) -> Bool {
        id.count <= 255 && id.contains(".") && id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { byte in (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 }
        }
    }

    static func bundleInfo(at path: String) -> [String: Any]? {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let stamp = try? Files.stamp(info.path), stamp.kind == 1, stamp.size < 2_000_000,
              let data = try? Data(contentsOf: info),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return object
    }

    static func bundleID(at path: String) -> String? {
        guard let id = bundleInfo(at: path)?["CFBundleIdentifier"] as? String, validBundleID(id) else { return nil }
        return id
    }
}
