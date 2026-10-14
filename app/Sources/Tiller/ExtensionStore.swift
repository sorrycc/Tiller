import AppKit
import CryptoKit

enum ExtensionError: LocalizedError {
    case noManifest(String)
    case badManifest(String)
    case theme(String)
    case app(String)
    case alreadyAdded(String)
    case comma(String)
    case badCRX
    case unzip(String)

    var errorDescription: String? {
        switch self {
        case .noManifest(let path): "\(path) has no manifest.json, so it isn't an unpacked extension."
        case .badManifest(let detail): "The extension's manifest.json can't be read: \(detail)"
        case .theme(let name): "\(name) is a theme, which Tiller doesn't use."
        case .app(let name): "\(name) is a Chrome app, which Tiller can't run."
        case .alreadyAdded(let name): "\(name) is already added."
        case .comma(let path): "Chromium can't load an extension whose path has a comma: \(path)"
        case .badCRX: "The file isn't a CRX package."
        case .unzip(let detail): "The CRX package couldn't be unpacked: \(detail)"
        }
    }
}

/// What Tiller reads from an extension's manifest.json.
struct ExtensionManifest: Sendable {
    let id: String
    let folder: String
    let name: String
    let version: String
    let manifestVersion: Int
    /// Paths inside the folder.
    let popup: String?
    let options: String?
    let icon: String?
    let actionTitle: String?

    var popupURL: String? { popup.map { "chrome-extension://\(id)/\($0)" } }
    var optionsURL: String? { options.map { "chrome-extension://\(id)/\($0)" } }

    /// The extension's toolbar icon, or its general one, at `size` points.
    /// Without either, a tile with its initial, as Chrome shows.
    @MainActor func image(size: CGFloat) -> NSImage {
        let key = "\(folder)/\(icon ?? "")@\(size)" as NSString
        if let cached = Self.images.object(forKey: key) { return cached }
        let image: NSImage
        if let file = icon, let loaded = NSImage(contentsOfFile: folder + "/" + file) {
            loaded.size = NSSize(width: size, height: size)
            image = loaded
        } else {
            image = initialTile(size: size)
        }
        Self.images.setObject(image, forKey: key)
        return image
    }

    /// Icons by folder, file and size: the menu and the bar ask for the same
    /// ones each time they are built, and decoding a PNG isn't free.
    @MainActor private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private func initialTile(size: CGFloat) -> NSImage {
        let initial = String(name.prefix(1)).uppercased()
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.systemGray.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size / 4, yRadius: size / 4).fill()
            let text = NSAttributedString(string: initial, attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.65, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
    }

    /// Reads the manifest in `folder`. Themes and Chrome apps are refused.
    static func read(_ folder: String) throws -> ExtensionManifest {
        guard let data = FileManager.default.contents(atPath: folder + "/manifest.json") else {
            throw ExtensionError.noManifest(folder)
        }
        let json: [String: Any]
        do {
            json = try parseJSON(data) as? [String: Any] ?? [:]
        } catch let error as ExtensionError {
            throw error
        } catch {
            throw ExtensionError.badManifest(error.localizedDescription)
        }
        let messages = Self.messages(in: folder, defaultLocale: json["default_locale"] as? String)
        let localize = { (text: String?) -> String? in text.map { Self.localize($0, messages) } }
        let name = localize(json["name"] as? String) ?? ""
        guard !name.isEmpty else { throw ExtensionError.badManifest("it has no name") }
        if json["theme"] != nil { throw ExtensionError.theme(name) }
        if json["app"] != nil { throw ExtensionError.app(name) }

        let action = (json["action"] ?? json["browser_action"] ?? json["page_action"]) as? [String: Any]
        let options = (json["options_ui"] as? [String: Any])?["page"] as? String ?? json["options_page"] as? String
        let id = (json["key"] as? String).flatMap { Data(base64Encoded: $0) }.map(Self.id(for:))
            ?? Self.id(forPath: folder)
        return ExtensionManifest(
            id: id, folder: folder, name: name,
            version: json["version"] as? String ?? "",
            manifestVersion: json["manifest_version"] as? Int ?? 0,
            popup: (action?["default_popup"] as? String).flatMap(Self.relative),
            options: options.flatMap(Self.relative),
            icon: Self.bestIcon(action?["default_icon"]) ?? Self.bestIcon(json["icons"]),
            actionTitle: localize(action?["default_title"] as? String)
        )
    }

    /// JSON with comments, which Chromium takes in manifests. It refuses
    /// trailing commas, and so does this.
    static func parseJSON(_ data: Data) throws -> Any {
        var output = [UInt8]()
        let bytes = [UInt8](data)
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if inString {
                output.append(byte)
                if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                    output.append(next)
                    index += 1
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                continue
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }
                index += 2
                output.append(UInt8(ascii: " "))
                continue
            } else {
                if byte == UInt8(ascii: "\"") { inString = true }
                // Foundation takes trailing commas too, so they're caught here.
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]"),
                    output.last(where: { ![0x20, 0x09, 0x0a, 0x0d].contains($0) }) == UInt8(ascii: ",")
                {
                    throw ExtensionError.badManifest("it has a trailing comma, which Chromium refuses")
                }
                output.append(byte)
            }
            index += 1
        }
        return try JSONSerialization.jsonObject(with: Data(output))
    }

    // MARK: Ids

    /// Chromium's id for a public key: the first 16 bytes of its SHA-256, with
    /// each hex digit written as a letter from a to p.
    static func id(for key: Data) -> String {
        let hash = SHA256.hash(data: key)
        return String(hash.prefix(16).flatMap { [$0 >> 4, $0 & 0xf] }.map { Character(UnicodeScalar(97 + $0)) })
    }

    /// The id Chromium gives an unpacked extension without a key, made from
    /// its folder's real path, as Chrome's Load unpacked does.
    static func id(forPath folder: String) -> String {
        id(for: Data(realPath(folder).utf8))
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Manifest details

    private static func relative(_ path: String) -> String? {
        let trimmed = path.drop { $0 == "/" }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    /// The smallest icon of at least 32 pixels, for 16 points on a Retina
    /// screen, or else the largest.
    private static func bestIcon(_ value: Any?) -> String? {
        if let path = value as? String { return relative(path) }
        guard let icons = value as? [String: String] else { return nil }
        let sized = icons.compactMap { key, path in Int(key).map { ($0, path) } }.sorted { $0.0 < $1.0 }
        return (sized.first { $0.0 >= 32 } ?? sized.last).flatMap { relative($0.1) }
    }

    /// Chromium runs in English, so names are shown as it shows them: from
    /// English messages, else the extension's default locale.
    private static func messages(in folder: String, defaultLocale: String?) -> [String: String] {
        var messages: [String: String] = [:]
        for locale in [defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            let path = "\(folder)/_locales/\(locale)/messages.json"
            guard let data = FileManager.default.contents(atPath: path),
                let json = try? parseJSON(data) as? [String: Any]
            else { continue }
            for (key, value) in json {
                if let message = (value as? [String: Any])?["message"] as? String {
                    messages[key.lowercased()] = message
                }
            }
        }
        return messages
    }

    /// Replaces a `__MSG_name__` value with its message.
    private static func localize(_ text: String, _ messages: [String: String]) -> String {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let key = text.dropFirst(6).dropLast(2).lowercased()
        return messages[key] ?? text
    }
}

/// The extensions, listed in `extensions.json` in the root folder. Chromium
/// loads the enabled ones as unpacked extensions at launch, into every
/// profile, so adding, removing or switching one takes effect at the next
/// launch and for every profile. Packages Tiller unpacks (CRX files and
/// Chrome's copies) live in the root's `Extensions` folder; folders added
/// directly are loaded where they are.
@MainActor
final class ExtensionStore {
    static let shared = ExtensionStore()

    enum Source: String, Codable {
        /// An unpacked folder, loaded where it is.
        case folder
        case crx
        case chrome

        /// Tiller made the folder and deletes it with the extension.
        var owned: Bool { self != .folder }
    }

    struct Entry: Codable, Equatable {
        var path: String
        var source: Source
        var enabled: Bool
        /// Has its own button in the toolbar, besides the Extensions menu.
        var pinned: Bool
    }

    private(set) var entries: [Entry]
    /// What Tiller asked Chromium to load at launch, in list order.
    let loaded: [ExtensionManifest]
    /// The last launch quit within moments of starting, so this one loads no
    /// extensions. An extension opening a tab as Chromium starts can crash
    /// CEF (chromiumembedded/cef#4285), and would again at every launch,
    /// before Settings could switch it off. They load again at the next launch.
    let skippedAfterCrash: Bool
    /// Why Chromium couldn't load some of them, by real path. Chromium writes
    /// these to its log while it starts, before any window opens.
    private lazy var loadErrors: [String: String] = Self.readLoadErrors()
    /// What Chromium loaded and runs.
    var running: [ExtensionManifest] {
        // Nothing loaded means nothing to check the log for.
        loaded.isEmpty ? [] : loaded.filter { loadError(forFolder: $0.folder) == nil }
    }

    /// Why Chromium couldn't load the extension in `folder` at launch.
    func loadError(forFolder folder: String) -> String? {
        loadErrors[ExtensionManifest.realPath(folder)]
    }
    private let launchPaths: [String]
    private var manifests: [String: Result<ExtensionManifest, Error>] = [:]

    private let path = ExtensionStore.listPath
    static let listPath = Profiles.root + "/extensions.json"
    static let folder = Profiles.root + "/Extensions"
    /// There while a launch that loads extensions is starting. Still there at
    /// the next launch, it means that one quit before `startedFine`.
    private static let startingPath = Profiles.root + "/ExtensionsStarting"

    private init() {
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        var loaded: [ExtensionManifest] = []
        for entry in entries where entry.enabled && !entry.path.contains(",") {
            guard let manifest = try? ExtensionManifest.read(entry.path) else { continue }
            loaded.append(manifest)
        }
        let manager = FileManager.default
        skippedAfterCrash = !loaded.isEmpty && manager.fileExists(atPath: Self.startingPath)
        if skippedAfterCrash {
            loaded = []
            try? manager.removeItem(atPath: Self.startingPath)
        } else if !loaded.isEmpty {
            manager.createFile(atPath: Self.startingPath, contents: nil)
        }
        self.loaded = loaded
        launchPaths = loaded.map(\.folder)
        Self.removeLater(unusedFolders())
    }

    /// The launch got past the moments after Chromium starts, when extensions
    /// open their install pages, or quit normally.
    func startedFine() {
        try? FileManager.default.removeItem(atPath: Self.startingPath)
    }

    /// Deletes folders off the main thread. An unpacked extension can be
    /// thousands of files; the window needn't wait for them.
    private nonisolated static func removeLater(_ folders: [String]) {
        guard !folders.isEmpty else { return }
        Task.detached(priority: .utility) {
            for folder in folders { try? FileManager.default.removeItem(atPath: folder) }
        }
    }

    /// The folders for `tiller_core_start`, one per line.
    var launchArgument: String { launchPaths.joined(separator: "\n") }

    func manifest(for entry: Entry) -> Result<ExtensionManifest, Error> {
        if let cached = manifests[entry.path] { return cached }
        let result = Result { try ExtensionManifest.read(entry.path) }
        manifests[entry.path] = result
        return result
    }

    func isLoaded(_ entry: Entry) -> Bool { launchPaths.contains(entry.path) }

    /// Whether the next launch loads something other than this one did.
    var needsRestart: Bool {
        entries.filter { $0.enabled && !$0.path.contains(",") && (try? manifest(for: $0).get()) != nil }.map(\.path)
            != launchPaths
    }

    // MARK: Changes

    /// Adds an unpacked extension folder, loaded where it is.
    @discardableResult
    func addFolder(_ folder: String) throws -> ExtensionManifest {
        let folder = ExtensionManifest.realPath(folder)
        if folder.contains(",") { throw ExtensionError.comma(folder) }
        let manifest = try ExtensionManifest.read(folder)
        if entries.contains(where: { $0.path == folder || id(of: $0) == manifest.id }) {
            throw ExtensionError.alreadyAdded(manifest.name)
        }
        manifests[folder] = .success(manifest)
        entries.append(Entry(path: folder, source: .folder, enabled: true, pinned: false))
        save()
        return manifest
    }

    /// Unpacks a CRX file into Tiller's folder and adds it, replacing an earlier
    /// copy of the same extension.
    @discardableResult
    func addCRX(_ file: String) async throws -> ExtensionManifest {
        let target = Self.folder
        let (folder, manifest) = try await Task.detached {
            let folder = try CRXPackage.unpack(file, into: target)
            do {
                return (folder, try ExtensionManifest.read(folder))
            } catch {
                try? FileManager.default.removeItem(atPath: folder)
                throw error
            }
        }.value
        return try install(manifest, at: folder, source: .crx, enabled: true)
    }

    /// Copies extensions found in a Chrome profile into Tiller. An extension
    /// already here is updated and keeps whether it's on. Returns how many
    /// were imported and how many were skipped.
    func importFromChrome(_ found: [ChromeExtension]) async -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0
        for chrome in found {
            if chrome.unpacked {
                // A folder Chrome loads unpacked stays where it is.
                if let manifest = try? addFolder(chrome.folder) {
                    setEnabled(chrome.enabled, id: manifest.id)
                    imported += 1
                } else if entries.contains(where: { $0.path == ExtensionManifest.realPath(chrome.folder) }) {
                    imported += 1
                } else {
                    skipped += 1
                }
                continue
            }
            let target = Self.folder
            let copied = await Task.detached { () -> Result<(String, ExtensionManifest), Error> in
                Result {
                    let folder = try Self.copy(chrome.folder, into: target, id: chrome.id)
                    do {
                        return (folder, try ExtensionManifest.read(folder))
                    } catch {
                        try? FileManager.default.removeItem(atPath: folder)
                        throw error
                    }
                }
            }.value
            guard case .success(let (folder, manifest)) = copied,
                (try? install(manifest, at: folder, source: .chrome, enabled: chrome.enabled)) != nil
            else {
                skipped += 1
                continue
            }
            imported += 1
        }
        return (imported, skipped)
    }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard entries.indices.contains(index), entries[index].enabled != enabled else { return }
        entries[index].enabled = enabled
        save()
    }

    func setPinned(_ pinned: Bool, at index: Int) {
        guard entries.indices.contains(index), entries[index].pinned != pinned else { return }
        entries[index].pinned = pinned
        save()
    }

    /// Takes the extensions out of the list. Folders Tiller made are deleted,
    /// unless Chromium has them loaded; those go at the next launch.
    func remove(at indexes: IndexSet) {
        for index in indexes.sorted(by: >) where entries.indices.contains(index) {
            let entry = entries.remove(at: index)
            manifests[entry.path] = nil
            if entry.source.owned && !launchPaths.contains(entry.path) {
                Self.removeLater([entry.path])
            }
        }
        save()
    }

    /// Chromium's "Failed to load extension from: <folder>. <reason>" lines
    /// in `chrome_debug.log`, which it starts afresh at each launch. They are
    /// written while Chromium starts, so only the start of the log is read:
    /// by the time Settings asks, a long session may have grown it a lot.
    private static func readLoadErrors() -> [String: String] {
        guard let handle = FileHandle(forReadingAtPath: Profiles.chromiumRoot + "/chrome_debug.log"),
            let data = try? handle.read(upToCount: 1 << 20)
        else { return [:] }
        try? handle.close()
        let log = String(decoding: data, as: UTF8.self)
        let marker = "Failed to load extension from: "
        var errors: [String: String] = [:]
        for line in log.split(separator: "\n") {
            guard let start = line.range(of: marker)?.upperBound else { continue }
            let rest = line[start...]
            // The folder ends at the first ". " that leaves a folder, since
            // the folder's name may have one too.
            var search = rest.startIndex
            while let dot = rest.range(of: ". ", range: search..<rest.endIndex) {
                let folder = String(rest[..<dot.lowerBound])
                if FileManager.default.fileExists(atPath: folder) {
                    errors[folder] = String(rest[dot.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
                search = dot.upperBound
            }
        }
        return errors
    }

    // MARK: Private

    private func id(of entry: Entry) -> String? {
        try? manifest(for: entry).get().id
    }

    private func setEnabled(_ enabled: Bool, id: String) {
        guard let index = entries.firstIndex(where: { self.id(of: $0) == id }) else { return }
        setEnabled(enabled, at: index)
    }

    /// Adds a folder Tiller unpacked or copied, in place of an earlier copy of
    /// the same extension. A folder added directly with that id wins.
    private func install(_ manifest: ExtensionManifest, at folder: String, source: Source, enabled: Bool) throws -> ExtensionManifest {
        manifests[folder] = .success(manifest)
        guard let index = entries.firstIndex(where: { id(of: $0) == manifest.id }) else {
            entries.append(Entry(path: folder, source: source, enabled: enabled, pinned: false))
            save()
            return manifest
        }
        let old = entries[index]
        guard old.source.owned else {
            Self.removeLater([folder])
            throw ExtensionError.alreadyAdded(manifest.name)
        }
        entries[index].path = folder
        entries[index].source = source
        manifests[old.path] = nil
        if !launchPaths.contains(old.path) { Self.removeLater([old.path]) }
        save()
        return manifest
    }

    /// Copies an extension's folder to a new folder under `target`, leaving
    /// out Chrome's `_metadata`, which only the Web Store's checks use.
    nonisolated private static func copy(_ source: String, into target: String, id: String) throws -> String {
        let folder = newFolder(in: target, id: id)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source, toPath: folder)
        try? FileManager.default.removeItem(atPath: folder + "/_metadata")
        return folder
    }

    /// A folder name that is new each time, so an update never writes over
    /// files Chromium has loaded.
    nonisolated static func newFolder(in target: String, id: String) -> String {
        "\(target)/\(id)_\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Folders under `Extensions` that no entry uses any more, such as ones
    /// removed while they were loaded.
    private func unusedFolders() -> [String] {
        let used = Set(entries.map(\.path))
        let items = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder)) ?? []
        return items.map { Self.folder + "/" + $0 }.filter { !used.contains($0) }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            NSLog("Tiller: could not save extensions: %@", error.localizedDescription)
        }
        NotificationCenter.default.post(name: .extensionsDidChange, object: nil)
    }
}

/// Chrome's extension package: a header with the publisher's key and
/// signature, followed by a ZIP of the extension.
enum CRXPackage {
    /// Unpacks `file` into a new folder under `target` and returns it. The
    /// package's key goes into manifest.json when it has none, so the
    /// extension keeps the id it has in Chrome.
    static func unpack(_ file: String, into target: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: file) else { throw ExtensionError.badCRX }
        let (key, zip) = try parse(data)
        let folder = ExtensionStore.newFolder(in: target, id: ExtensionManifest.id(for: key))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tiller-crx-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }
        try zip.write(to: temp)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", temp.path, folder]
        let errors = Pipe()
        ditto.standardError = errors
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: folder)
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExtensionError.unzip(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? FileManager.default.removeItem(atPath: folder + "/_metadata")
        addKey(key, to: folder + "/manifest.json")
        return folder
    }

    /// The public key and the ZIP from a CRX2 or CRX3 package.
    static func parse(_ data: Data) throws -> (key: Data, zip: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 16, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] /* Cr24 */ else { throw ExtensionError.badCRX }
        let word = { (at: Int) -> Int in
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        switch word(4) {
        case 2:
            let keyLength = word(8)
            let signatureLength = word(12)
            let start = 16 + keyLength + signatureLength
            guard start <= bytes.count else { throw ExtensionError.badCRX }
            return (Data(bytes[16..<16 + keyLength]), Data(bytes[start...]))
        case 3:
            let headerLength = word(8)
            let start = 12 + headerLength
            guard start <= bytes.count else { throw ExtensionError.badCRX }
            let key = try crx3Key(Array(bytes[12..<start]))
            return (key, Data(bytes[start...]))
        default:
            throw ExtensionError.badCRX
        }
    }

    /// The key in a CRX3 header whose hash is the package's id. The header is
    /// a CrxFileHeader protobuf: key proofs in fields 2 (RSA) and 3 (ECDSA),
    /// each with the key in field 1, and the id in field 1 of field 10000.
    private static func crx3Key(_ header: [UInt8]) throws -> Data {
        var keys: [Data] = []
        var crxID: Data?
        for (field, value) in fields(header) {
            if field == 2 || field == 3 {
                if let key = fields(value).first(where: { $0.0 == 1 }) { keys.append(Data(key.1)) }
            } else if field == 10000 {
                crxID = fields(value).first { $0.0 == 1 }.map { Data($0.1) }
            }
        }
        let key = keys.first { key in crxID.map { Data(SHA256.hash(data: key).prefix(16)) == $0 } ?? true }
        guard let key else { throw ExtensionError.badCRX }
        return key
    }

    /// The length-delimited fields of a protobuf message, skipping the rest.
    private static func fields(_ bytes: [UInt8]) -> [(Int, [UInt8])] {
        var result: [(Int, [UInt8])] = []
        var index = 0
        func varint() -> Int? {
            var value = 0
            var shift = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count, let tag = varint() {
            switch tag & 7 {
            case 0: guard varint() != nil else { return result }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = varint(), length >= 0, index + length <= bytes.count else { return result }
                result.append((tag >> 3, Array(bytes[index..<index + length])))
                index += length
            default: return result
            }
        }
        return result
    }

    /// Puts `"key"` first in the manifest, leaving the rest of the text as it is.
    private static func addKey(_ key: Data, to manifest: String) {
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8),
            let json = try? ExtensionManifest.parseJSON(Data(text.utf8)) as? [String: Any],
            json["key"] == nil, let brace = text.firstIndex(of: "{")
        else { return }
        var updated = text
        updated.insert(contentsOf: "\n  \"key\": \"\(key.base64EncodedString())\",", at: updated.index(after: brace))
        try? updated.write(toFile: manifest, atomically: true, encoding: .utf8)
    }
}

extension Notification.Name {
    static let extensionsDidChange = Notification.Name("TillerExtensionsDidChange")
}
