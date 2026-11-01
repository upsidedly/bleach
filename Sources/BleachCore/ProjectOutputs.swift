import Foundation

enum ProjectOutputs {
    static func regular(_ url: URL, limit: Int64 = 5_000_000) -> Bool {
        guard let stamp = try? Files.stamp(url.path) else { return false }
        return stamp.kind == 1 && !stamp.dataless && stamp.size <= limit
    }

    static func swiftProject(for output: URL, requireContents: Bool = true) -> URL? {
        let scratch = output.deletingLastPathComponent()
        let project: URL
        if scratch.lastPathComponent == ".build" { project = scratch.deletingLastPathComponent() }
        else if ["spm", "tests", "checks"].contains(scratch.lastPathComponent), scratch.deletingLastPathComponent().lastPathComponent == "build" {
            project = scratch.deletingLastPathComponent().deletingLastPathComponent()
        } else { return nil }
        guard regular(project.appendingPathComponent("Package.swift")),
              output.lastPathComponent.range(of: "^(arm64|x86_64)-apple-macosx[0-9.]*$", options: .regularExpression) != nil,
              !requireContents || ["debug", "release"].contains(where: { regular(output.appendingPathComponent("\($0)/description.json")) }) else { return nil }
        return project
    }

    static func nextProject(for output: URL) -> URL? {
        guard regular(output.appendingPathComponent("BUILD_ID"), limit: 1024),
              ["build-manifest.json", "routes-manifest.json"].allSatisfy({ regular(output.appendingPathComponent($0)) }),
              ["server", "static"].allSatisfy({ (try? Files.stamp(output.appendingPathComponent($0).path).kind) == 2 }) else { return nil }
        var parent = output.deletingLastPathComponent()
        for _ in 0..<6 {
            let manifest = parent.appendingPathComponent("package.json")
            if regular(manifest), let data = try? Data(contentsOf: manifest), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["dependencies"] as? [String: Any])?["next"] != nil || (json["devDependencies"] as? [String: Any])?["next"] != nil { return parent }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    static func matches(_ output: URL) -> Bool { swiftProject(for: output) != nil || nextProject(for: output) != nil }

    static func swiftOutputs(in project: URL) -> [URL] {
        guard regular(project.appendingPathComponent("Package.swift")) else { return [] }
        return [".build", "build/spm", "build/tests", "build/checks"].flatMap { relative in
            (try? Files.children(project.appendingPathComponent(relative).path))?.filter { swiftProject(for: $0) != nil } ?? []
        }
    }
}
