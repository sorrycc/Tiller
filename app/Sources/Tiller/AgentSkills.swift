import Foundation

enum SkillError: LocalizedError {
    case noSkill(String)
    case badName(String)
    case badFile(String)
    case notInLibrary(name: String, path: String)
    case unknown(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .noSkill(let path): "\(path) has no SKILL.md, in it or in the folders inside it."
        case .badName(let name): "\"\(name)\" can't be a skill name. Use letters, digits, dots, dashes and underscores, up to 64."
        case .badFile(let path): "\"\(path)\" isn't a path inside the skill's folder."
        case .notInLibrary(let name, let path):
            "\(name) is a user skill at \(path), which Tiller doesn't change. Save it under another name, or add its folder in Settings > Skills first."
        case .unknown(let name): "No skill named \(name)."
        case .install(let detail): detail
        }
    }
}

/// A skill an agent can call with `/name`: a folder with a SKILL.md, whose
/// front matter gives its name and what it does.
struct AgentSkill: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// Tiller's library for the profile.
        case library
        case command
        /// One of the CLI's own folders, or a plugin's.
        case user
    }

    let name: String
    let description: String
    let argumentHint: String?
    /// The SKILL.md. Nil for a skill only the CLI listed, which Tiller found no file for.
    let path: String?
    let origin: Origin

    var folder: String? { path.map { ($0 as NSString).deletingLastPathComponent } }

    /// Reads `folder/SKILL.md`. Without a name in its front matter the
    /// folder's name is used, as the CLIs do. `prefix` namespaces plugin skills.
    static func read(folder: String, origin: Origin, prefix: String? = nil) -> AgentSkill? {
        let path = folder + "/SKILL.md"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let fields = frontMatter(text)
        let base = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (folder as NSString).lastPathComponent
        return AgentSkill(
            name: prefix.map { "\($0):\(base)" } ?? base,
            description: fields["description"] ?? "",
            argumentHint: fields["argument-hint"].flatMap { $0.isEmpty ? nil : $0 },
            path: path,
            origin: origin
        )
    }

    /// The `key: value` lines between the leading `---` lines. Quoted values
    /// are unquoted, and `>` or `|` values take the indented lines after them.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(">") || value.hasPrefix("|") {
                var block: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: value.hasPrefix(">") ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
                if first == "\"" { value = value.replacingOccurrences(of: "\\\"", with: "\"") }
            }
            fields[key] = value
        }
        return fields
    }

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
            CharacterSet.alphanumerics.contains(first)
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}

/// The profile's skill library, in `agent-skills` in its folder:
/// `skills.json` lists the skills, `library/<name>` holds each one, and
/// `exposed` links the enabled ones where the CLIs look. Claude Code and
/// Qoder CLI get `exposed` with `--add-dir` and read its `.claude/skills` and
/// `.qoder/skills`, and Antigravity CLI its `.agents/skills`; Codex gets
/// `exposed/skills` as an extra skills root, and Grok Build in `[skills]`
/// paths of its config.toml.
@MainActor
final class AgentSkillStore {
    enum Source: String, Codable {
        case folder
        case archive
        case git
        /// Written by an agent with save_skill.
        case agent

        var displayName: String {
            switch self {
            case .folder: "Folder"
            case .archive: "Archive"
            case .git: "Git"
            case .agent: "Agent"
            }
        }
    }

    struct Entry: Codable, Equatable {
        var name: String
        var source: Source
        /// The folder, file or URL it came from. Empty for one an agent wrote.
        var origin: String
        var enabled: Bool
    }

    private(set) var entries: [Entry]
    private var skills: [String: AgentSkill] = [:]

    nonisolated let root: String
    private let libraryFolder: String
    /// Passed to Claude Code, Qoder CLI and Antigravity CLI with `--add-dir`.
    nonisolated let exposedFolder: String
    /// Codex's extra skills root.
    nonisolated let exposedSkills: String
    private let indexPath: String
    private let settings: ProfileSettings

    /// Creates the folders that --add-dir and Codex's skills root name.
    init(folder: String, settings: ProfileSettings) {
        self.settings = settings
        root = folder + "/agent-skills"
        libraryFolder = root + "/library"
        exposedFolder = root + "/exposed"
        exposedSkills = exposedFolder + "/skills"
        indexPath = root + "/skills.json"
        let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath))
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        syncExposed()
    }

    func folder(for name: String) -> String { libraryFolder + "/" + name }

    /// The skill as its SKILL.md says now. Nil if the file is gone or unreadable.
    func skill(for entry: Entry) -> AgentSkill? {
        if let cached = skills[entry.name] { return cached }
        let skill = AgentSkill.read(folder: folder(for: entry.name), origin: .library)
        skills[entry.name] = skill
        return skill
    }

    /// The enabled skills, as the agents see them.
    var enabledSkills: [AgentSkill] {
        entries.filter(\.enabled).compactMap(skill(for:))
    }

    // MARK: Adding

    /// Copies the skill in `path`, or every skill in the folders inside it.
    /// Returns their names.
    func addFolder(_ path: String) async throws -> [String] {
        try await install(from: path, source: .folder, origin: path)
    }

    /// Unpacks a .zip or .skill archive and adds the skills in it.
    func addArchive(_ file: String) async throws -> [String] {
        let temp = Self.tempFolder()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try await Task.detached {
            try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", file, temp], failure: "The archive couldn't be unpacked")
        }.value
        return try await install(from: temp, source: .archive, origin: file)
    }

    /// Clones a repository and adds the skills in it. Takes a clone URL,
    /// `owner/repo` on GitHub, or a GitHub folder link (`…/tree/<branch>/<path>`).
    func addGit(_ input: String) async throws -> [String] {
        let (url, branch, subfolder) = Self.parseGit(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let git = await Task.detached(operation: { Self.gitExecutable() }).value else {
            throw SkillError.install("git not found. Install the Xcode command line tools with xcode-select --install.")
        }
        let temp = Self.tempFolder()
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try await Task.detached {
            var arguments = ["clone", "--depth", "1", "--quiet"]
            if let branch { arguments += ["--branch", branch] }
            try Self.run(git, arguments + [url, temp], failure: "git couldn't clone \(url)")
        }.value
        let source = subfolder.map { temp + "/" + $0 } ?? temp
        return try await install(from: source, source: .git, origin: input)
    }

    /// Copies each skill found in `path` into the library, replacing one of
    /// the same name, which stays on or off as it was.
    private func install(from path: String, source: Source, origin: String) async throws -> [String] {
        let library = libraryFolder
        let found = try await Task.detached { () -> [(String, String)] in
            let folders = Self.skillFolders(in: path)
            guard !folders.isEmpty else { throw SkillError.noSkill(path) }
            return try folders.map { folder in
                guard let skill = AgentSkill.read(folder: folder, origin: .library) else { throw SkillError.noSkill(folder) }
                guard AgentSkill.isValidName(skill.name) else { throw SkillError.badName(skill.name) }
                return (skill.name, folder)
            }
        }.value
        var names: [String] = []
        for (name, folder) in found {
            let target = library + "/" + name
            try await Task.detached {
                try Self.replace(target) { try FileManager.default.copyItem(atPath: folder, toPath: $0) }
                try? FileManager.default.removeItem(atPath: target + "/.git")
            }.value
            upsert(Entry(name: name, source: source, origin: source == .archive || source == .git ? origin : folder, enabled: true))
            names.append(name)
        }
        save()
        return names
    }

    /// The folder itself if it has a SKILL.md, else its subfolders that do.
    /// With none, looks inside a `skills` folder, or inside the only folder
    /// there is, as archives and repositories often wrap their skills.
    nonisolated private static func skillFolders(in path: String, depth: Int = 0) -> [String] {
        let manager = FileManager.default
        if manager.fileExists(atPath: path + "/SKILL.md") { return [path] }
        let children = ((try? manager.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            .sorted()
            .map { path + "/" + $0 }
            .filter { var isDirectory: ObjCBool = false; return manager.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue }
        let skills = children.filter { manager.fileExists(atPath: $0 + "/SKILL.md") }
        if !skills.isEmpty || depth >= 3 { return skills }
        if manager.fileExists(atPath: path + "/skills") { return skillFolders(in: path + "/skills", depth: depth + 1) }
        if children.count == 1 { return skillFolders(in: children[0], depth: depth + 1) }
        return []
    }

    // MARK: Agent writes

    /// Creates or updates a library skill for an agent's save_skill call.
    /// `content` is the whole SKILL.md, or its body when `description` is
    /// given. `files` are written beside it and `deleteFiles` removed; other
    /// files the skill has stay. Refuses a name only a user skill has.
    func save(name: String, description: String?, content: String, files: [String: String], deleteFiles: [String]) throws -> AgentSkill {
        guard AgentSkill.isValidName(name) else { throw SkillError.badName(name) }
        let existing = entries.firstIndex { $0.name == name }
        if existing == nil, let user = AgentSkillCatalog.userSkills(for: nil, workFolder: settings.agentFolderPath).first(where: { $0.name == name }) {
            throw SkillError.notInLibrary(name: name, path: user.path ?? "")
        }
        var text = content
        if !text.hasPrefix("---") {
            guard let description, !description.isEmpty else {
                throw SkillError.install("content has no front matter, so description is required.")
            }
            text = "---\nname: \(name)\ndescription: \(Self.yamlString(description))\n---\n\n" + text
        } else if let own = AgentSkill.frontMatter(text)["name"], !own.isEmpty, own != name {
            throw SkillError.install("The front matter names the skill \(own), not \(name).")
        }
        let target = folder(for: name)
        for path in files.keys + deleteFiles {
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }),
                path != "SKILL.md"
            else { throw SkillError.badFile(path) }
        }
        let manager = FileManager.default
        try manager.createDirectory(atPath: target, withIntermediateDirectories: true)
        try text.write(toFile: target + "/SKILL.md", atomically: true, encoding: .utf8)
        for (path, body) in files {
            let url = URL(fileURLWithPath: target + "/" + path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            // Scripts the skill runs.
            if body.hasPrefix("#!") { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        for path in deleteFiles { try? manager.removeItem(atPath: target + "/" + path) }
        if existing != nil {
            skills[name] = nil
        } else {
            entries.append(Entry(name: name, source: .agent, origin: "", enabled: true))
        }
        save()
        guard let skill = skill(for: entries.first { $0.name == name }!) else { throw SkillError.noSkill(target) }
        return skill
    }

    // MARK: Changes

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard entries.indices.contains(index), entries[index].enabled != enabled else { return }
        entries[index].enabled = enabled
        save()
    }

    /// Takes the skills out of the library and deletes their folders.
    func remove(at indexes: IndexSet) {
        for index in indexes.sorted(by: >) where entries.indices.contains(index) {
            let entry = entries.remove(at: index)
            skills[entry.name] = nil
            try? FileManager.default.removeItem(atPath: folder(for: entry.name))
        }
        save()
    }

    private func upsert(_ entry: Entry) {
        skills[entry.name] = nil
        if let index = entries.firstIndex(where: { $0.name == entry.name }) {
            entries[index].source = entry.source
            entries[index].origin = entry.origin
        } else {
            entries.append(entry)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: URL(fileURLWithPath: indexPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexPath)
        } catch {
            NSLog("Tiller: could not save skills: %@", error.localizedDescription)
        }
        syncExposed()
        NotificationCenter.default.post(name: .agentSkillsDidChange, object: self)
    }

    /// Links each enabled skill into `exposed/skills`, and points
    /// `exposed/.claude/skills`, `exposed/.qoder/skills` and
    /// `exposed/.agents/skills` at it.
    private func syncExposed() {
        let manager = FileManager.default
        let skillsFolder = exposedSkills
        try? manager.createDirectory(atPath: skillsFolder, withIntermediateDirectories: true)
        for cli in [".claude", ".qoder", ".agents"] {
            let folder = exposedFolder + "/" + cli
            let link = folder + "/skills"
            try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if (try? manager.destinationOfSymbolicLink(atPath: link)) != "../skills" {
                try? manager.removeItem(atPath: link)
                try? manager.createSymbolicLink(atPath: link, withDestinationPath: "../skills")
            }
        }
        let wanted = Set(entries.filter(\.enabled).map(\.name))
        for name in (try? manager.contentsOfDirectory(atPath: skillsFolder)) ?? [] where !wanted.contains(name) {
            try? manager.removeItem(atPath: skillsFolder + "/" + name)
        }
        for name in wanted {
            let link = skillsFolder + "/" + name
            let destination = "../../library/" + name
            if (try? manager.destinationOfSymbolicLink(atPath: link)) != destination {
                try? manager.removeItem(atPath: link)
                try? manager.createSymbolicLink(atPath: link, withDestinationPath: destination)
            }
        }
    }

    // MARK: Helpers

    nonisolated private static func tempFolder() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("tiller-skill-\(UUID().uuidString)").path
    }

    /// Builds the new folder beside `target`, then swaps it in, so a failed
    /// copy leaves the old skill alone.
    nonisolated private static func replace(_ target: String, build: (String) throws -> Void) throws {
        let manager = FileManager.default
        let parent = (target as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let staging = parent + "/.staging-" + UUID().uuidString
        do {
            try build(staging)
        } catch {
            try? manager.removeItem(atPath: staging)
            throw error
        }
        try? manager.removeItem(atPath: target)
        try manager.moveItem(atPath: staging, toPath: target)
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // A private repository would otherwise wait for a password nobody can type.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SkillError.install(message.isEmpty ? failure + "." : failure + ": " + message)
        }
    }

    nonisolated private static func gitExecutable() -> String? {
        // /usr/bin/git is a stub that asks to install the tools when they're missing.
        let developer = Process()
        developer.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        developer.arguments = ["-p"]
        developer.standardOutput = FileHandle.nullDevice
        developer.standardError = FileHandle.nullDevice
        if (try? developer.run()) != nil {
            developer.waitUntilExit()
            if developer.terminationStatus == 0 { return "/usr/bin/git" }
        }
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return AgentEnvironment.loginShellLookup("git")
    }

    /// The clone URL, branch and folder inside the repository.
    nonisolated static func parseGit(_ input: String) -> (url: String, branch: String?, subfolder: String?) {
        let shorthand = input.split(separator: "/")
        if !input.contains(":"), shorthand.count == 2, !input.hasPrefix(".") {
            return ("https://github.com/\(input).git", nil, nil)
        }
        if let url = URL(string: input), url.host() == "github.com" {
            let parts = url.path().split(separator: "/").map(String.init)
            if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
                let rest = parts.dropFirst(4).joined(separator: "/")
                let folder = parts[2] == "blob" ? (rest as NSString).deletingLastPathComponent : rest
                return ("https://github.com/\(parts[0])/\(parts[1]).git", parts[3], folder.isEmpty ? nil : folder)
            }
        }
        return (input, nil, nil)
    }

    nonisolated private static func yamlString(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\"" + flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Every skill an agent can call: Tiller's library and the CLI's own.
@MainActor
enum AgentSkillCatalog {
    /// What `/` offers before the CLI has said what it loaded: the library's
    /// enabled skills, then the user's own for that CLI, one per name.
    static func skills(for kind: AgentKind, library: AgentSkillStore) -> [AgentSkill] {
        unique(library.enabledSkills + userSkills(for: kind))
    }

    /// The skills the CLI said it loaded, described from their files where
    /// Tiller finds them: the library's enabled skills first, then `scanned`,
    /// what `scanSkills` read for the CLI.
    static func skills(named names: [String], scanned: [AgentSkill], kind: AgentKind, library: AgentSkillStore) -> [AgentSkill] {
        var known: [String: AgentSkill] = [:]
        for skill in library.enabledSkills + scanned where known[skill.name] == nil { known[skill.name] = skill }
        return names.map { known[$0] ?? AgentSkill(name: $0, description: "", argumentHint: nil, path: nil, origin: .user) }
    }

    /// The CLI's own skills and its plugins', from their files. `plugins` are
    /// folders whose `skills` hold more. Many plugins mean many files, so a
    /// session asks off the main thread.
    nonisolated static func scanSkills(plugins: [(name: String, path: String)], kind: AgentKind) -> [AgentSkill] {
        userSkills(for: kind) + plugins.flatMap { plugin in
            folders(in: plugin.path + "/skills").compactMap { AgentSkill.read(folder: $0, origin: .user, prefix: plugin.name) }
        }
    }

    /// The CLI's own skills, from its user folders and the working folder's.
    /// `nil` takes every CLI's.
    nonisolated static func userSkills(for kind: AgentKind?, workFolder: String? = nil) -> [AgentSkill] {
        let home = NSHomeDirectory()
        let claude = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
        var roots: [String] = []
        let kinds = kind.map { [$0] } ?? AgentKind.allCases
        for kind in kinds {
            switch kind {
            case .claude: roots += [claude + "/skills"] + (workFolder.map { [$0 + "/.claude/skills"] } ?? [])
            case .qodercli: roots += [home + "/.agents/skills", home + "/.qoder/skills"] + (workFolder.map { [$0 + "/.qoder/skills"] } ?? [])
            case .codex: roots += [home + "/.agents/skills"] + (workFolder.map { [$0 + "/.agents/skills"] } ?? [])
            case .agy: roots += [home + "/.gemini/config/skills"] + (workFolder.map { [$0 + "/.agents/skills"] } ?? [])
            case .grok:
                roots += [home + "/.grok/skills", home + "/.agents/skills"]
                    + (workFolder.map { [$0 + "/.grok/skills", $0 + "/.agents/skills"] } ?? [])
            }
        }
        var seen = Set<String>()
        return roots.flatMap(folders(in:)).compactMap { folder in
            let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted else { return nil }
            return AgentSkill.read(folder: folder, origin: .user)
        }
    }

    nonisolated private static func folders(in root: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { root + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0 + "/SKILL.md") }
    }

    private static func unique(_ skills: [AgentSkill]) -> [AgentSkill] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.name).inserted }
    }

    // MARK: Control socket

    /// list_skills, read_skill and save_skill from tiller_mcp.
    static func control(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let store = profile.skills
        switch method {
        case "skills.list":
            let library = store.entries.compactMap { entry -> [String: Any]? in
                guard let skill = store.skill(for: entry) else { return nil }
                return ["name": skill.name, "description": skill.description, "path": skill.path ?? "",
                        "editable": true, "enabled": entry.enabled]
            }
            let names = Set(store.entries.map(\.name))
            let workFolder = profile.settings.agentFolderPath
            // The CLIs' folders are read off the main thread.
            return deferred {
                userSkills(for: nil, workFolder: workFolder).filter { !names.contains($0.name) }
            } then: { user in
                ["skills": library + user.map {
                    ["name": $0.name, "description": $0.description, "path": $0.path ?? "", "editable": false, "enabled": true] as [String: Any]
                }]
            }
        case "skills.read":
            guard let name = params["name"] as? String, !name.isEmpty else { throw ControlError("read_skill needs a name") }
            let editable = store.entries.contains { $0.name == name }
            // The library's skill is known here; the CLIs' folders, the file
            // and the folder's listing are read off the main thread.
            let library = store.entries.first { $0.name == name }.flatMap(store.skill(for:))
            let workFolder = profile.settings.agentFolderPath
            return deferred { () throws -> (name: String, path: String, content: String, files: [String]) in
                guard let skill = library ?? userSkills(for: nil, workFolder: workFolder).first(where: { $0.name == name }),
                    let path = skill.path, let folder = skill.folder
                else {
                    throw ControlError(SkillError.unknown(name).localizedDescription)
                }
                let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                var files: [String] = []
                if let walker = FileManager.default.enumerator(atPath: folder) {
                    while let file = walker.nextObject() as? String, files.count < 200 {
                        if file.hasPrefix(".") || file.contains("/.") { walker.skipDescendants(); continue }
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: folder + "/" + file, isDirectory: &isDirectory), !isDirectory.boolValue {
                            files.append(file)
                        }
                    }
                }
                return (name: skill.name, path: path, content: content, files: files)
            } then: { found in
                ["name": found.name, "path": found.path, "editable": editable, "content": found.content, "files": found.files] as [String: Any]
            }
        case "skills.save":
            guard let name = params["name"] as? String, !name.isEmpty else { throw ControlError("save_skill needs a name") }
            guard let content = params["content"] as? String, !content.isEmpty else { throw ControlError("save_skill needs content") }
            let isNew = !store.entries.contains { $0.name == name }
            do {
                let skill = try store.save(
                    name: name,
                    description: params["description"] as? String,
                    content: content,
                    files: params["files"] as? [String: String] ?? [:],
                    deleteFiles: params["delete_files"] as? [String] ?? []
                )
                let enabled = store.entries.first { $0.name == name }?.enabled ?? true
                return [
                    "saved": skill.name, "path": skill.path ?? "", "created": isNew,
                    "note": enabled
                        ? "Agents load it when they next start, so call it with /\(skill.name) in a new chat."
                        : "It is turned off in Settings > Skills, so agents don't load it.",
                ]
            } catch {
                throw ControlError(error.localizedDescription)
            }
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    /// Answers later with what `finish` makes, on the main actor, of what
    /// `work` found off it.
    private static func deferred<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T, then finish: @escaping (T) -> Any
    ) -> ControlDeferred {
        ControlDeferred { reply in
            Task { @MainActor in
                do {
                    let value = try await Task.detached(priority: .userInitiated) { try work() }.value
                    reply(.success(finish(value)))
                } catch {
                    reply(.failure(error as? ControlError ?? ControlError(error.localizedDescription)))
                }
            }
        }
    }
}

extension Notification.Name {
    static let agentSkillsDidChange = Notification.Name("TillerAgentSkillsDidChange")
}
