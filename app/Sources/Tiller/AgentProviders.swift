import AppKit
import Security

/// An endpoint the user added for an agent CLI, such as DeepSeek's
/// Anthropic-compatible API for Claude Code, or a relay's Responses API for
/// Codex. Chats on it run the same CLI, pointed at `baseURL` with the
/// provider's key and models. The key is kept in the Keychain, not here.
struct AgentProvider: Codable, Equatable {
    /// Which header the key goes in: Claude Code sends `ANTHROPIC_API_KEY` as
    /// `x-api-key` and `ANTHROPIC_AUTH_TOKEN` as a Bearer token.
    enum Auth: String, Codable, CaseIterable {
        case apiKey
        case authToken

        var displayName: String {
            switch self {
            case .apiKey: "API Key (x-api-key)"
            case .authToken: "Auth Token (Bearer)"
            }
        }

        var variable: String {
            switch self {
            case .apiKey: "ANTHROPIC_API_KEY"
            case .authToken: "ANTHROPIC_AUTH_TOKEN"
            }
        }
    }

    let id: String
    var name: String
    /// The CLI it runs.
    var kind: AgentKind
    var baseURL: String
    /// The first is used when the chat picks none.
    var models: [String]
    var auth: Auth
    /// `KEY=VALUE` lines, set after Tiller's own variables.
    var extraEnvironment: String

    init(name: String, kind: AgentKind = .claude, baseURL: String, models: [String], auth: Auth, extraEnvironment: String) {
        id = UUID().uuidString
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.models = models
        self.auth = auth
        self.extraEnvironment = extraEnvironment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, models, auth, extraEnvironment
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decodeIfPresent(AgentKind.self, forKey: .kind) ?? .claude
        baseURL = try values.decode(String.self, forKey: .baseURL)
        models = try values.decode([String].self, forKey: .models)
        auth = try values.decode(Auth.self, forKey: .auth)
        extraEnvironment = try values.decode(String.self, forKey: .extraEnvironment)
    }

    /// Codex's provider overrides, after `app-server`. The key stays in the environment.
    var codexArguments: [String] {
        guard kind == .codex else { return [] }
        let values = [
            ("model_provider", "tiller"),
            ("model_providers.tiller.name", name),
            ("model_providers.tiller.base_url", baseURL),
            ("model_providers.tiller.env_key", "TILLER_PROVIDER_API_KEY"),
            ("model_providers.tiller.wire_api", "responses"),
        ]
        return values.flatMap { ["-c", "\($0.0)=\(Self.tomlString($0.1))"] }
    }

    /// A TOML basic string, including control characters pasted into a field.
    private static func tomlString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0...0x1F, 0x7F: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// `extraEnvironment` read as variables. Blank lines and `#` comments are
    /// skipped, a leading `export` is allowed, and quotes around a value go.
    static func variables(in text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !key.contains(" ") else { return nil }
            return (key, value)
        }
    }

    /// The variables Claude Code runs with on this provider: its URL and key,
    /// and `model` (or the provider's first) for every model role, so
    /// background requests such as titles don't ask it for a Claude model.
    /// Codex gets its key as `TILLER_PROVIDER_API_KEY`.
    /// Then the extra ones, which can override any of them.
    func apply(to env: inout [String: String], model: String?) {
        if kind == .codex {
            env["TILLER_PROVIDER_API_KEY"] = AgentProviderKeychain.read(id)
            for (key, value) in Self.variables(in: extraEnvironment) { env[key] = value }
            return
        }
        for key in env.keys where key.hasPrefix("ANTHROPIC_") { env[key] = nil }
        env["ANTHROPIC_BASE_URL"] = baseURL
        if let key = AgentProviderKeychain.read(id), !key.isEmpty { env[auth.variable] = key }
        if let model = model ?? models.first {
            for key in [
                "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
            ] {
                env[key] = model
            }
        }
        for (key, value) in Self.variables(in: extraEnvironment) { env[key] = value }
    }
}

/// The profile's providers, in its defaults.
@MainActor
final class AgentProviderStore {
    private static let defaultsKey = "agentProviders"
    private(set) var providers: [AgentProvider]
    let settings: ProfileSettings
    /// Greys out unavailable agents in this profile's agent pop-ups.
    private(set) lazy var menuAvailability = AgentMenuAvailability(providers: self)

    init(settings: ProfileSettings) {
        self.settings = settings
        providers = settings.defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([AgentProvider].self, from: $0) } ?? []
    }

    func provider(_ id: String) -> AgentProvider? {
        providers.first { $0.id == id }
    }

    /// Adds or replaces it.
    func save(_ provider: AgentProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        write()
    }

    /// Chats on it stay in history, but can't run again. Its key goes too.
    func remove(_ id: String) {
        providers.removeAll { $0.id == id }
        AgentProviderKeychain.delete(id)
        if current.provider == id { current = AgentChoice(.claude) }
        write()
    }

    private func write() {
        settings.defaults.set(try? JSONEncoder().encode(providers), forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .agentProvidersDidChange, object: self)
    }

    // MARK: Choices

    /// The provider's settings. Nil without one, or once it was removed.
    func providerConfig(_ choice: AgentChoice) -> AgentProvider? {
        choice.provider.flatMap(provider)
    }

    /// Whether it can run: a removed provider can't.
    func exists(_ choice: AgentChoice) -> Bool {
        choice.provider == nil || providerConfig(choice) != nil
    }

    func displayName(_ choice: AgentChoice) -> String {
        guard let provider = choice.provider else { return choice.kind.displayName }
        return self.provider(provider)?.name ?? "Removed Provider"
    }

    /// Why it can't be picked: its CLI isn't there. Nil when it can, or
    /// while the CLI is still being looked up.
    func unavailableReason(_ choice: AgentChoice) -> String? {
        let kind = choice.kind
        guard AgentEnvironment.isAvailable(kind, settings: settings) == false else { return nil }
        if let path = settings.agentPath(for: kind) {
            return "\(path) is not an executable file. Fix the \(kind.displayName) path in Settings (Cmd+,)."
        }
        return "\(kind.rawValue) not found. Install it, or set its path in Settings (Cmd+,)."
    }

    /// Every CLI, then the providers.
    var all: [AgentChoice] {
        AgentKind.allCases.map { AgentChoice($0) } + providers.map { AgentChoice($0.kind, provider: $0.id) }
    }

    /// What new chats start with. A removed provider falls back to its CLI.
    var current: AgentChoice {
        get {
            guard let choice = settings.defaults.string(forKey: "agent").flatMap(AgentChoice.init) else { return AgentChoice(.qodercli) }
            return exists(choice) ? choice : AgentChoice(choice.kind)
        }
        set {
            guard newValue != current else { return }
            settings.defaults.set(newValue.rawValue, forKey: "agent")
            NotificationCenter.default.post(name: .agentKindDidChange, object: self)
        }
    }

    /// The models to offer for `choice`: the CLI's, or the provider's own.
    func models(for choice: AgentChoice) -> [AgentModel] {
        guard choice.provider != nil else { return AgentModelCatalog.models(for: choice.kind) }
        return (providerConfig(choice)?.models ?? []).map { AgentModel(id: $0, name: $0, efforts: nil, fastTier: nil, isDefault: false) }
    }
}

/// Providers' keys, one generic password each, by provider id.
enum AgentProviderKeychain {
    private static let service = "Tiller Agent Provider"

    private static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    static func read(_ id: String) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty key removes it.
    static func write(_ key: String, for id: String) {
        delete(id)
        guard !key.isEmpty else { return }
        var add = query(id)
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = service
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// What a chat or schedule runs: a CLI, on its own login or on a provider
/// the user added. Saved as the CLI's name, or `<kind>:<provider id>`.
struct AgentChoice: Hashable, RawRepresentable {
    var kind: AgentKind
    /// The provider's id. Nil uses the CLI's own setup.
    var provider: String?

    init(_ kind: AgentKind, provider: String? = nil) {
        self.kind = kind
        self.provider = provider
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let kind = AgentKind(rawValue: first) else { return nil }
        self.kind = kind
        provider = parts.count == 2 && !parts[1].isEmpty ? parts[1] : nil
    }

    var rawValue: String { provider.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    @MainActor
    func logo(size: CGFloat) -> NSImage? { kind.logo(size: size) }
}

extension Notification.Name {
    /// Posted when a provider is added, changed or removed.
    static let agentProvidersDidChange = Notification.Name("TillerAgentProvidersDidChange")
}

/// Greys out the agents whose CLI isn't there in an agent pop-up's menu,
/// with why as the tooltip. Checked each time the menu opens, so a CLI
/// installed or given a path since then can be picked.
@MainActor
final class AgentMenuAvailability: NSObject, NSMenuDelegate {
    private unowned let providers: AgentProviderStore

    init(providers: AgentProviderStore) {
        self.providers = providers
    }

    /// `popUp`'s items name agents by `AgentChoice.rawValue`, which are
    /// checked against the CLIs and paths of the profile `providers` has.
    static func watch(_ popUp: NSPopUpButton, providers: AgentProviderStore) {
        popUp.autoenablesItems = false
        popUp.menu?.delegate = providers.menuAvailability
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let choice = (item.representedObject as? String).flatMap(AgentChoice.init) else { continue }
            let reason = providers.unavailableReason(choice)
            item.isEnabled = reason == nil
            item.toolTip = reason
        }
        AgentEnvironment.refreshAvailability(settings: providers.settings)
    }
}
