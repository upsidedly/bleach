import Foundation

/// Declarative boundaries only: never run a package manager or read shell files.
/// Recomputed by policy, so a saved plan cannot invent a configured cache path.
enum CacheLocations {
    static let environmentKeys = ["NPM_CONFIG_CACHE", "npm_config_cache", "PIP_CACHE_DIR", "PIP_CONFIG_FILE", "XDG_CACHE_HOME", "GRADLE_USER_HOME", "CARGO_HOME", "GOCACHE", "GOENV"]

    static func seeds(context: ScanContext) -> [CandidateSeed] {
        let env = context.cacheEnvironment
        var result: [CandidateSeed] = []
        func add(_ path: String?, _ kind: CacheProof.Kind, _ title: String, _ consequence: String) {
            guard let path, safe(path, context: context) else { return }
            let components = kind == .cargoArchives ? 2 : (kind == .prisma || kind == .goBuild ? 0 : 1)
            var root = URL(fileURLWithPath: path)
            for _ in 0..<components { root.deleteLastPathComponent() }
            result.append(CandidateSeed(path: path, title: title, category: .developer, rule: .packageDownloadCache,
                reason: "A documented download or compiler cache; installed packages and source stay in place.", consequence: consequence,
                cacheProof: CacheProof(kind: kind, root: root.path)))
        }
        func child(_ root: String?, _ name: String) -> String? { root.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path } }
        func path(_ value: String?) -> String? { resolve(value, context: context) }
        func config(_ relative: String) -> String? { read(context.homeURL(relative), context: context) }

        let npm = path(env["NPM_CONFIG_CACHE"] ?? env["npm_config_cache"] ?? value(config(".npmrc"), key: "cache"))
        add(child(npm, "_cacache"), .npm, "npm package cache", "npm downloads these packages again when needed.")
        add(child(npm, "_npx"), .npx, "npx command cache", "npx downloads these commands again when needed. Active commands are retained.")

        // Only these cache buckets are authorized for a custom pip root. A
        // mistaken cache-dir pointing at Documents cannot select Documents.
        let pipFiles = [".pip/pip.conf", ".config/pip/pip.conf", "Library/Application Support/pip/pip.conf"]
        var pip: String?
        for file in pipFiles {
            if let configured = value(config(file), key: "cache-dir", section: "global") { pip = configured }
        }
        if let file = path(env["PIP_CONFIG_FILE"]), let configured = value(read(URL(fileURLWithPath: file), context: context), key: "cache-dir", section: "global") { pip = configured }
        let pipRoot = path(env["PIP_CACHE_DIR"] ?? pip) ?? child(path(env["XDG_CACHE_HOME"]), "pip")
        if let pipRoot, ![context.homeURL(".cache/pip").path, context.homeURL("Library/Caches/pip").path].contains(pipRoot) {
            for bucket in ["http", "http-v2", "wheels", "selfcheck"] {
                add(child(pipRoot, bucket), .pip, "pip \(bucket) cache", "pip downloads or rebuilds cached packages again. Installed environments stay.")
            }
        }
        add(child(path(env["GRADLE_USER_HOME"]), "caches"), .gradle, "Gradle caches", "Gradle downloads dependencies and rebuilds caches. JDKs and wrappers stay.")
        let cargo = path(env["CARGO_HOME"]) ?? context.homeURL(".cargo").path
        add(child(cargo, "registry/cache"), .cargoArchives, "Cargo download archives", "Cargo downloads crate archives again. Registry source, Git checkouts, credentials and installed commands stay.")
        add(context.homeURL(".cache/prisma").path, .prisma, "Prisma engine downloads", "Prisma downloads these cached engines again. Project engines stay.")

        let goFile = path(env["GOENV"]) ?? context.homeURL("Library/Application Support/go/env").path
        let go = path(env["GOCACHE"] ?? value(read(URL(fileURLWithPath: goFile), context: context), key: "GOCACHE"))
        if let go, go != context.homeURL("Library/Caches/go-build").path {
            // The tool's own marker distinguishes a build cache from a
            // misconfigured source directory. Keep it required at apply time.
            if read(URL(fileURLWithPath: go).appendingPathComponent("README"), context: context)?.hasPrefix("This directory holds cached build artifacts from the Go build system.") == true {
                add(go, .goBuild, "Go build cache", "Go recompiles cached build artifacts. Module source and installed commands stay.")
            }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.path).inserted }
    }

    static func matches(_ candidate: CleanupCandidate, context: ScanContext, restoring: Bool) -> Bool {
        guard let proof = candidate.cacheProof, safe(candidate.path, context: context), resolve(proof.root, context: context) != nil else { return false }
        let root = URL(fileURLWithPath: proof.root)
        let expected: [String]
        switch proof.kind {
        case .npm: expected = [root.appendingPathComponent("_cacache").path]
        case .npx: expected = [root.appendingPathComponent("_npx").path]
        case .pip: expected = ["http", "http-v2", "wheels", "selfcheck"].map { root.appendingPathComponent($0).path }
        case .gradle: expected = [root.appendingPathComponent("caches").path]
        case .cargoArchives: expected = [root.appendingPathComponent("registry/cache").path]
        case .prisma: expected = [context.homeURL(".cache/prisma").path]
        case .goBuild: expected = [proof.root]
        }
        guard expected.contains(candidate.path) else { return false }
        // Restore uses the original, previously validated typed boundary in the
        // private journal. Changing tool settings must not strand a backup.
        return restoring || seeds(context: context).contains { $0.path == candidate.path && $0.cacheProof == proof }
    }

    static func resolve(_ value: String?, context: ScanContext) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("~/") { value = context.home.path + String(value.dropFirst()) }
        // No variable expansion, command substitution, URLs or relative paths.
        guard value.hasPrefix("/"), !value.contains("$"), !value.contains("`"), !value.contains("\0"),
              Files.lexicalPath(value) == value, Files.pathIsWithin(value, context.home.path), value != context.home.path else { return nil }
        return value
    }

    static func safe(_ path: String, context: ScanContext) -> Bool {
        guard resolve(path, context: context) != nil else { return false }
        let relative = String(path.dropFirst(context.home.path.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        let lower = components.map { $0.lowercased() }
        let protected: Set<String> = [".codex", ".t3", ".claude", ".local", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".config", ".trash", ".git", ".venv", "node_modules", "cloudstorage", "mobile documents", "dropbox", "onedrive", "google drive", "icloud drive", "id_rsa", "id_ed25519", "credentials"]
        let suffixes = [".pem", ".p12", ".pfx", ".key", ".app", ".bundle", ".photolibrary", ".photoslibrary", ".framework", ".backupbundle", ".sparsebundle"]
        guard !lower.contains(where: { component in
            protected.contains(component) || component.hasPrefix("onedrive - ") || component == ".env" ||
                component.hasPrefix(".env.") || suffixes.contains(where: component.hasSuffix)
        }) else { return false }
        let loweredPath = lower.joined(separator: "/")
        let linkedStores = [".cache/uv", ".cache/codex-runtimes", ".bun", ".yarn", "library/caches/uv", "library/caches/bun", "library/caches/yarn", "library/caches/pnpm"]
        guard !linkedStores.contains(where: { loweredPath == $0 || loweredPath.hasPrefix($0 + "/") }) else { return false }
        // A moved cache may live in Library, but never in app databases,
        // containers, keychains, browser profiles or cloud/document stores.
        if lower.first == "library", !loweredPath.hasPrefix("library/caches/") { return false }
        return components.count >= 2
    }

    static func read(_ url: URL, context: ScanContext) -> String? {
        guard Files.pathIsWithin(url.path, context.home.path),
              (try? Files.ensureRealDirectory(url.deletingLastPathComponent().path)) != nil,
              let stamp = try? Files.stamp(url.path), stamp.kind == 1, !stamp.dataless,
              let data = try? Files.readPrivateFile(url, limit: 128_000) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func value(_ text: String?, key: String, section: String? = nil) -> String? {
        guard let text else { return nil }
        var current = "", result: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { current = String(line.dropFirst().dropLast()).lowercased(); continue }
            guard section == nil || current == section, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() else { continue }
            var found = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if found.count >= 2, (found.first == "\"" && found.last == "\"") || (found.first == "'" && found.last == "'") { found = String(found.dropFirst().dropLast()) }
            result = found
        }
        return result
    }
}
