import AppKit

/// Settings > Providers: endpoints the user added for Claude Code or Codex, each
/// picked like an agent of its own in the panel, Settings and schedules.
final class ProvidersSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let table = SettingsTableView()
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: SettingsPane.tableWidth)
    private var placeholder: NSTextField?
    /// The editor sheet while it is open.
    private var editorWindow: NSWindow?
    private var providers: [AgentProvider] { store.providers }
    private let store: AgentProviderStore

    init(profile: ProfileContext) {
        store = profile.providers
        super.init(nibName: nil, bundle: nil)
        title = "Providers"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("name", "Name", 140.0), ("url", "Base URL", 300.0), ("models", "Models", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(edit(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Providers")
        self.placeholder = placeholder

        for (button, action) in [
            (addButton, #selector(add(_:))),
            (editButton, #selector(edit(_:))),
            (removeButton, #selector(remove(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addButton, editButton, NSView(), removeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [tableBox, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsPane.tableWidth),
            scroll.heightAnchor.constraint(equalToConstant: SettingsPane.tableHeight),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .agentProvidersDidChange, object: store)
        reload(nil)
        SettingsPane.show(
            "Run Claude Code against an Anthropic-compatible API, or Codex against an OpenAI Responses-compatible API. Each provider shows "
                + "as an agent of its own in the panel's menu, with its own models. Keys are kept in the Keychain.",
            in: note
        )
    }

    @objc private func reload(_ notification: Notification?) {
        let selected = table.selectedRow
        table.reloadData()
        if providers.indices.contains(selected) { table.selectRowIndexes([selected], byExtendingSelection: false) }
        updateControls()
    }

    private func updateControls() {
        let selected = providers.indices.contains(table.selectedRow)
        editButton.isEnabled = selected
        removeButton.isEnabled = selected
        placeholder?.isHidden = !providers.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { providers.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard providers.indices.contains(row) else { return nil }
        let provider = providers[row]
        let text = switch column?.identifier.rawValue {
        case "name": "\(provider.name) (\(provider.kind.displayName))"
        case "url": provider.baseURL
        default: provider.models.joined(separator: ", ")
        }
        let cell = SettingsPane.textCell(tableView, text)
        cell.textField?.toolTip = text
        if column?.identifier.rawValue != "name" { cell.textField?.textColor = .secondaryLabelColor }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func add(_ sender: Any?) {
        presentEditor(for: nil)
    }

    @objc private func edit(_ sender: Any?) {
        let row = sender as? NSTableView === table && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard providers.indices.contains(row) else { return }
        presentEditor(for: providers[row])
    }

    /// Edit > Delete and the Delete key remove the selected provider, after asking.
    @objc func delete(_ sender: Any?) {
        guard removeButton.isEnabled else { return NSSound.beep() }
        remove(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(delete(_:)) ? removeButton.isEnabled : true
    }

    private func presentEditor(for provider: AgentProvider?) {
        guard let window = view.window, editorWindow == nil else { return }
        let editor = ProviderEditorController(provider: provider)
        let sheet = NSWindow(contentViewController: editor)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        editor.onDone = { [weak self, weak window, weak sheet] saved in
            if let sheet { window?.endSheet(sheet) }
            self?.editorWindow = nil
            guard let (provider, key) = saved else { return }
            AgentProviderKeychain.write(key, for: provider.id)
            self?.store.save(provider)
        }
        editorWindow = sheet
        window.beginSheet(sheet)
    }

    /// Asks first. Chats on it stay in history but can't run again.
    @objc private func remove(_ sender: Any?) {
        guard providers.indices.contains(table.selectedRow), let window = view.window else { return }
        let provider = providers[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = "Remove “\(provider.name)”?"
        alert.informativeText = "Its key is deleted from the Keychain. Its chats stay in history but can't continue, and schedules using it fail until changed."
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.store.remove(provider.id) }
        }
    }
}

/// The sheet that adds or edits a provider.
final class ProviderEditorController: NSViewController {
    /// Called with the edited provider and its key, or nil when cancelled.
    var onDone: (((provider: AgentProvider, key: String)?) -> Void)?

    private let original: AgentProvider?
    private let grid = NSGridView()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let kindPopUp = NSPopUpButton()
    private let authPopUp = NSPopUpButton()
    private var authRow: NSGridRow?
    private var authNoteRow: NSGridRow?
    private let modelsField = NSTextField()
    private var envView: NSTextView!
    private let errorNote = SettingsPane.note()

    private static let fieldWidth: CGFloat = 380

    init(provider: AgentProvider?) {
        original = provider
        super.init(nibName: nil, bundle: nil)
        title = provider == nil ? "New Provider" : "Edit Provider"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let provider = original
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = provider?.name ?? ""
        nameField.placeholderString = "DeepSeek"
        addRow("Name:", nameField)
        for kind in [AgentKind.claude, .codex] {
            kindPopUp.addItem(withTitle: kind.displayName)
            kindPopUp.lastItem?.representedObject = kind.rawValue
        }
        kindPopUp.selectItem(at: provider?.kind == .codex ? 1 : 0)
        kindPopUp.isEnabled = provider == nil
        kindPopUp.target = self
        kindPopUp.action = #selector(kindChanged(_:))
        addRow("Agent:", kindPopUp)

        urlField.stringValue = provider?.baseURL ?? ""
        urlField.placeholderString = "https://api.deepseek.com/anthropic"
        addRow("Base URL:", urlField)

        keyField.stringValue = provider.flatMap { AgentProviderKeychain.read($0.id) } ?? ""
        keyField.placeholderString = "sk-…"
        addRow("API key:", keyField)

        for auth in AgentProvider.Auth.allCases {
            authPopUp.addItem(withTitle: auth.displayName)
            authPopUp.lastItem?.representedObject = auth.rawValue
        }
        authPopUp.selectItem(at: AgentProvider.Auth.allCases.firstIndex(of: provider?.auth ?? .apiKey) ?? 0)
        authRow = addRow("Send key as:", authPopUp)
        addNote(SettingsPane.note("ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN. Check the provider's docs."))
        authNoteRow = grid.row(at: grid.numberOfRows - 1)

        modelsField.stringValue = provider?.models.joined(separator: ", ") ?? ""
        modelsField.placeholderString = "deepseek-chat, deepseek-reasoner"
        addRow("Models:", modelsField)
        addNote(SettingsPane.note("Comma separated. The first is used when a chat picks none."))

        let scroll = BoxedTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = Theme.Radius.small
        box.borderColor = Theme.hairline
        box.fillColor = Theme.fill(Theme.Fill.rest)
        box.contentViewMargins = NSSize(width: 1, height: 1)
        box.contentView = scroll
        box.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        box.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let textView = scroll.documentView as! NSTextView
        textView.drawsBackground = false
        textView.string = provider?.extraEnvironment ?? ""
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.setAccessibilityLabel("Extra environment")
        envView = textView
        let envRow = addRow("Environment:", box)
        envRow.rowAlignment = .none
        envRow.cell(at: 0).yPlacement = .top
        addNote(SettingsPane.note("Optional KEY=VALUE lines, set last, such as API_TIMEOUT_MS=600000."))
        grid.column(at: 0).xPlacement = .trailing
        for field in [nameField, urlField, keyField, modelsField] {
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.bezelColor = .controlAccentColor
        errorNote.textColor = .systemRed
        errorNote.lineBreakMode = .byWordWrapping
        errorNote.maximumNumberOfLines = 2
        errorNote.preferredMaxLayoutWidth = 300
        let buttons = NSStackView(views: [errorNote, NSView(), cancel, save])
        buttons.spacing = 8

        let view = NSView()
        for subview in [grid, buttons] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        self.view = view
        kindChanged(nil)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private var selectedKind: AgentKind {
        (kindPopUp.selectedItem?.representedObject as? String).flatMap(AgentKind.init) ?? .claude
    }

    @objc private func kindChanged(_ sender: Any?) {
        let codex = selectedKind == .codex
        authRow?.isHidden = codex
        authNoteRow?.isHidden = codex
        nameField.placeholderString = codex ? "OpenAI Compatible" : "DeepSeek"
        urlField.placeholderString = codex ? "https://example.com/v1" : "https://api.deepseek.com/anthropic"
        modelsField.placeholderString = codex ? "gpt-5.4" : "deepseek-chat, deepseek-reasoner"
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// A labeled row; VoiceOver reads the label as the control's title.
    @discardableResult
    private func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        let title = NSTextField(labelWithString: label)
        control.setAccessibilityTitleUIElement(title)
        return grid.addRow(with: [title, control])
    }

    private func addNote(_ note: NSTextField) {
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = Self.fieldWidth
        grid.addRow(with: [NSGridCell.emptyContentView, note])
    }

    @objc private func cancel(_ sender: Any?) {
        onDone?(nil)
    }

    @objc private func save(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = modelsField.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !name.isEmpty else { return showError("Name the provider.") }
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            return showError("The base URL starts with https://.")
        }
        guard !models.isEmpty else { return showError("Add at least one model.") }
        let auth = (authPopUp.selectedItem?.representedObject as? String).flatMap(AgentProvider.Auth.init) ?? .apiKey
        var provider = original ?? AgentProvider(name: name, kind: selectedKind, baseURL: url, models: models, auth: auth, extraEnvironment: "")
        provider.name = name
        provider.baseURL = url
        provider.models = models
        provider.auth = auth
        provider.extraEnvironment = envView.string
        onDone?((provider, key))
    }

    private func showError(_ text: String) {
        errorNote.stringValue = text
        NSSound.beep()
    }
}
