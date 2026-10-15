import AppKit

/// The command list embedded in Settings > Agent.
final class CommandsSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private let table = SettingsTableView()
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: 460)
    private var placeholder: NSTextField?
    /// The editor sheet while it is open.
    private var editorWindow: NSWindow?
    private var commands: [AgentCommand] { settings.agentCommands }
    private let settings: ProfileSettings

    init(profile: ProfileContext) {
        settings = profile.settings
        super.init(nibName: nil, bundle: nil)
        title = "Commands"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [("name", "Name", 140.0), ("command", "Command Line", 320.0)] {
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
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Commands")
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
            scroll.widthAnchor.constraint(equalToConstant: 460),
            scroll.heightAnchor.constraint(equalToConstant: 120),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        reload(nil)
        SettingsPane.show("Called with /name from the message field. The text and selected tab are sent as JSON on stdin.", in: note)
    }

    @objc private func reload(_ notification: Notification?) {
        let selected = table.selectedRow
        table.reloadData()
        if commands.indices.contains(selected) { table.selectRowIndexes([selected], byExtendingSelection: false) }
        updateControls()
    }

    private func updateControls() {
        let selected = commands.indices.contains(table.selectedRow)
        editButton.isEnabled = selected
        removeButton.isEnabled = selected
        placeholder?.isHidden = !commands.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row) else { return nil }
        let command = commands[row]
        let text = column?.identifier.rawValue == "name" ? command.name : command.commandLine
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
        guard commands.indices.contains(row) else { return }
        presentEditor(for: commands[row])
    }

    /// Edit > Delete and the Delete key remove the selected command, after asking.
    @objc func delete(_ sender: Any?) {
        guard removeButton.isEnabled else { return NSSound.beep() }
        remove(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(delete(_:)) ? removeButton.isEnabled : true
    }

    private func presentEditor(for command: AgentCommand?) {
        guard let window = view.window, editorWindow == nil else { return }
        let editor = CommandEditorController(command: command, others: commands.filter { $0.name != command?.name })
        let sheet = NSWindow(contentViewController: editor)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        editor.onDone = { [weak self, weak window, weak sheet] saved in
            if let sheet { window?.endSheet(sheet) }
            self?.editorWindow = nil
            guard let saved, let self else { return }
            var commands = self.commands
            if let command, let index = commands.firstIndex(where: { $0.name == command.name }) {
                commands[index] = saved
            } else {
                commands.append(saved)
            }
            self.settings.agentCommands = commands
            self.reload(nil)
        }
        editorWindow = sheet
        window.beginSheet(sheet)
    }

    @objc private func remove(_ sender: Any?) {
        guard commands.indices.contains(table.selectedRow), let window = view.window else { return }
        let command = commands[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = "Remove “\(command.name)”?"
        alert.informativeText = "It will no longer run from the message field."
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settings.agentCommands = self.commands.filter { $0.name != command.name }
                self.reload(nil)
            }
        }
    }
}

final class CommandEditorController: NSViewController {
    var onDone: ((AgentCommand?) -> Void)?
    private let original: AgentCommand?
    private let others: [AgentCommand]
    private let nameField = NSTextField()
    private let commandField = NSTextField()
    private let errorNote = SettingsPane.wrappingNote(width: 420)

    init(command: AgentCommand?, others: [AgentCommand]) {
        original = command
        self.others = others
        super.init(nibName: nil, bundle: nil)
        title = command == nil ? "New Command" : "Edit Command"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        nameField.stringValue = original?.name ?? ""
        commandField.stringValue = original?.commandLine ?? ""
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        for (label, field) in [("Name:", nameField), ("Command line:", commandField)] {
            let title = NSTextField(labelWithString: label)
            field.setAccessibilityTitleUIElement(title)
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            grid.addRow(with: [title, field])
        }
        grid.column(at: 0).xPlacement = .trailing
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.bezelColor = .controlAccentColor
        errorNote.textColor = .systemRed
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [grid, errorNote, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func cancel(_ sender: Any?) { onDone?(nil) }

    @objc private func save(_ sender: Any?) {
        let name = nameField.stringValue
        let commandLine = commandField.stringValue
        if let message = AgentCommand.validationMessage(name: name, commandLine: commandLine, others: others) {
            errorNote.stringValue = message
            NSSound.beep()
            return
        }
        onDone?(AgentCommand(name: name, commandLine: commandLine))
    }
}
