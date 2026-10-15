import AppKit
import Quartz

@MainActor
protocol AgentPanelDelegate: AnyObject {
    /// The selected tab, described for the agent at the start of each message.
    func agentPanelContext(_ panel: AgentPanelView) -> String
    func agentCommandContext(_ panel: AgentPanelView) -> [String: Any]
}

/// The side panel: pick an agent and chat with it, in up to a few tabs, each
/// with its own agent. A bar above the message field switches tabs, opens
/// new ones and past chats. The open tabs come back at the next launch.
/// Like the tab sidebar it has no background of its own, so it reads as one
/// surface with the toolbar.
final class AgentPanelView: NSView {
    weak var delegate: AgentPanelDelegate?
    /// Called when any chat starts or stops working.
    var onBusyChange: ((Bool) -> Void)?
    /// Whether any chat's agent is working.
    private(set) var isBusy = false {
        didSet { if isBusy != oldValue { onBusyChange?(isBusy) } }
    }

    /// The message being written in the selected tab.
    var input: NSView { active.input }

    private let agentPicker = NSPopUpButton()
    private let status = StatusPill()
    private let chatArea = NSView()
    private let tabBar = AgentTabBar()
    private var chats: [AgentChatView] = []
    /// Scheduled runs going on in the background. They take no tab until
    /// opened, and leave once their turn ends.
    private var scheduledChats: [AgentChatView] = []
    private var activeIndex = 0
    private var active: AgentChatView { chats[activeIndex] }
    private var historyPopover: NSPopover?

    private let profile: ProfileContext

    /// The panel of `profile`'s window, with its chats and agents.
    init(profile: ProfileContext, frame: NSRect) {
        self.profile = profile
        super.init(frame: frame)
        build()
        restoreTabs()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: profile.providers
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(tabLimitChanged(_:)), name: .agentTabsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(providersChanged(_:)), name: .agentProvidersDidChange, object: profile.providers
        )
        // A new chat follows Settings' options, and the button names the models.
        for name in [Notification.Name.agentModelOptionsDidChange, .agentModelsDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(tabLimitChanged(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The panel is on screen: have the CLIs looked up now, so the first
    /// message doesn't wait on a login shell and the agent picker knows
    /// which are missing.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        AgentEnvironment.refreshAvailability(settings: profile.settings)
        AgentModelCatalog.refreshAll(profile: profile)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        AgentEnvironment.refreshAvailability(settings: profile.settings)
        AgentModelCatalog.refreshAll(profile: profile)
    }

    /// Ends every tab's agent and saves the chats. Called when the window closes.
    func shutDown() {
        saveTabs()
        (chats + scheduledChats).forEach { $0.shutDown() }
        profile.agentHistory.flush()
        profile.agentHistory.waitForWrites()
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: Layout

    private func build() {
        fillAgentPicker()
        agentPicker.isBordered = false
        agentPicker.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        agentPicker.toolTip = "Agent for this chat"
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged(_:))
        AgentMenuAvailability.watch(agentPicker, providers: profile.providers)

        tabBar.onSelect = { [weak self] index in self?.select(index, focus: true) }
        tabBar.onClose = { [weak self] index in self?.closeTab(index) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        tabBar.onNewChat = { [weak self] in self?.newChat() }
        tabBar.onHistory = { [weak self] button in self?.showHistory(from: button) }

        for view in [agentPicker, status, chatArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            agentPicker.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            agentPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: agentPicker.trailingAnchor, constant: 4),
            status.centerYAnchor.constraint(equalTo: agentPicker.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            chatArea.topAnchor.constraint(equalTo: agentPicker.bottomAnchor, constant: 8),
            chatArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            chatArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            chatArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Tabs

    /// Last time's tabs, up to the limit. A chat since deleted opens empty.
    private func restoreTabs() {
        let store = profile.agentHistory
        for id in store.openTabs.prefix(profile.settings.agentTabs) {
            add(AgentChatView(profile: profile, conversation: id.isEmpty ? nil : store.conversation(id)))
        }
        if chats.isEmpty { add(AgentChatView(profile: profile)) }
        select(min(max(store.selectedTab, 0), chats.count - 1), focus: false)
    }

    private func add(_ chat: AgentChatView, at index: Int? = nil) {
        attach(chat)
        chats.insert(chat, at: index ?? chats.count)
    }

    /// Puts the chat in the panel, hidden, without giving it a tab.
    private func attach(_ chat: AgentChatView) {
        chat.context = { [weak self] in
            guard let self else { return "" }
            return self.delegate?.agentPanelContext(self) ?? ""
        }
        chat.commandContext = { [weak self] in
            guard let self else { return [:] }
            return self.delegate?.agentCommandContext(self) ?? [:]
        }
        chat.onChange = { [weak self, weak chat] in
            guard let self, let chat else { return }
            if self.chats.contains(chat) {
                self.refresh()
                self.saveTabs()
            } else if self.scheduledChats.contains(chat) {
                self.refresh()
            }
        }
        chat.onTools = { [weak self] button in self?.showTools(from: button) }
        chat.onModel = { [weak self] button in self?.showModelOptions(from: button) }
        chat.isHidden = true
        chat.translatesAutoresizingMaskIntoConstraints = false
        chatArea.addSubview(chat)
        NSLayoutConstraint.activate([
            chat.topAnchor.constraint(equalTo: chatArea.topAnchor),
            chat.bottomAnchor.constraint(equalTo: chatArea.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: chatArea.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: chatArea.trailingAnchor),
        ])
    }

    /// Shows the tab at `index`, with the tab bar moved into it.
    private func select(_ index: Int, focus: Bool) {
        activeIndex = index
        for (i, chat) in chats.enumerated() { chat.isHidden = i != index }
        let chat = active
        if tabBar.superview !== chat.tabBarHost {
            tabBar.removeFromSuperview()
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            chat.tabBarHost.addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: chat.tabBarHost.topAnchor),
                tabBar.bottomAnchor.constraint(equalTo: chat.tabBarHost.bottomAnchor),
                tabBar.leadingAnchor.constraint(equalTo: chat.tabBarHost.leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: chat.tabBarHost.trailingAnchor),
            ])
        }
        refresh()
        saveTabs()
        if focus { window?.makeFirstResponder(chat.input) }
    }

    private func newTab() {
        guard chats.count < profile.settings.agentTabs else { return NSSound.beep() }
        add(AgentChatView(profile: profile))
        select(chats.count - 1, focus: true)
    }

    /// Starts over in the selected tab. The chat it had stays in history.
    private func newChat() {
        if active.isEmpty {
            window?.makeFirstResponder(input)
        } else {
            replace(activeIndex, with: AgentChatView(profile: profile))
        }
    }

    private func replace(_ index: Int, with chat: AgentChatView) {
        let old = chats.remove(at: index)
        old.shutDown()
        old.removeFromSuperview()
        add(chat, at: index)
        select(index, focus: true)
    }

    /// Closing the last tab leaves a new chat.
    private func closeTab(_ index: Int) {
        guard chats.indices.contains(index) else { return }
        if chats.count == 1 { return newChat() }
        let chat = chats.remove(at: index)
        chat.shutDown()
        chat.removeFromSuperview()
        let selected = index < activeIndex ? activeIndex - 1 : min(activeIndex, chats.count - 1)
        select(selected, focus: hasKeyboardFocus || index == activeIndex)
    }

    private func saveTabs() {
        profile.agentHistory.setOpenTabs(chats.map { $0.isEmpty ? "" : $0.id }, selected: activeIndex)
    }

    /// The header and tab bar show the selected chat.
    private func refresh() {
        let chat = active
        isBusy = (chats + scheduledChats).contains { $0.isBusy }
        if let stale = agentPicker.lastItem, stale.representedObject == nil, !stale.isSeparatorItem {
            agentPicker.menu?.removeItem(stale)
        }
        if let index = agentPicker.itemArray.firstIndex(where: { $0.representedObject as? String == chat.choice.rawValue }) {
            agentPicker.selectItem(at: index)
        } else {
            // A removed provider's chat names it, without offering it.
            agentPicker.addItem(withTitle: profile.providers.displayName(chat.choice))
            agentPicker.lastItem?.image = chat.choice.logo(size: 16)
            agentPicker.lastItem?.isHidden = true
            agentPicker.select(agentPicker.lastItem)
        }
        status.show(chat.statusText, busy: chat.statusBusy)
        tabBar.update(
            tabs: chats.map { (title: $0.title, busy: $0.isBusy) },
            selected: activeIndex,
            canAddTab: chats.count < profile.settings.agentTabs
        )
        chat.showOptions()
    }

    // MARK: Model

    /// The selected chat's model, effort, context and fast mode. Locked while
    /// a turn runs, since a change restarts the agent.
    private func showModelOptions(from button: NSView) {
        let chat = active
        AgentModelMenu.popUp(
            from: button, above: true, kind: chat.choice, profile: profile, options: chat.modelOptions, locked: chat.isBusy,
            note: chat.isBusy ? "Stop the agent to change the model." : "Settings sets them for new chats."
        ) { [weak chat] options in
            chat?.setModelOptions(options)
        }
    }

    // MARK: Tools

    /// The selected chat's built-in tools, each a checkmark item. Codex can
    /// always read and run read-only commands, so writing and running
    /// commands widen its sandbox, and Antigravity CLI always has them all.
    /// Locked while a turn runs, since a change restarts the agent.
    private func showTools(from button: NSView) {
        let chat = active
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Also allow in this chat"))
        for tool in AgentTool.allCases {
            let item = NSMenuItem(title: tool.displayName, action: #selector(toggleTool(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            let alwaysOn = chat.kind.alwaysAllows(tool)
            item.state = alwaysOn || chat.tools.contains(tool) ? .on : .off
            item.isEnabled = !alwaysOn && !chat.isBusy
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(
            title: chat.isBusy ? "Stop the agent to change tools." : "They run without asking. Settings sets them for new chats.",
            action: nil, keyEquivalent: ""
        )
        note.isEnabled = false
        menu.addItem(note)
        // Above the button, which sits at the bottom of the message field.
        menu.popUp(above: button)
    }

    @objc private func toggleTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = AgentTool(rawValue: raw) else { return }
        let chat = active
        var tools = Set(chat.tools)
        if tools.contains(tool) { tools.remove(tool) } else { tools.insert(tool) }
        chat.setTools(AgentTool.allCases.filter(tools.contains))
    }

    @objc private func tabLimitChanged(_ notification: Notification) {
        refresh()
    }

    // MARK: History

    private func showHistory(from button: NSView) {
        if let historyPopover, historyPopover.isShown { return historyPopover.close() }
        let controller = AgentHistoryController(items: historyItems(), current: active.id)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.onOpen = { [weak self, weak popover] id in
            popover?.close()
            self?.open(id)
        }
        controller.onDelete = { [weak self, weak controller] id in
            guard let self else { return }
            self.delete(id)
            controller?.reload(self.historyItems())
        }
        historyPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func historyItems() -> [AgentHistoryController.Item] {
        profile.agentHistory.conversations.map { conversation in
            .init(
                conversation: conversation, tab: chats.firstIndex { $0.id == conversation.id },
                agentName: profile.providers.displayName(conversation.choice)
            )
        }
    }

    /// Switches to the chat if a tab has it, or opens it in the selected tab.
    func open(_ id: String) {
        open(id, newTabIfRoom: false)
    }

    /// Shows a scheduled run's chat: in a new tab while there is room, else
    /// in the selected tab.
    func openScheduled(_ id: String) {
        open(id, newTabIfRoom: true)
    }

    /// A run still going keeps going in its new tab.
    private func open(_ id: String, newTabIfRoom: Bool) {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            return select(index, focus: true)
        }
        let chat: AgentChatView
        if let index = scheduledChats.firstIndex(where: { $0.id == id }) {
            chat = scheduledChats.remove(at: index)
            chat.removeFromSuperview()
        } else {
            guard let conversation = profile.agentHistory.conversation(id) else { return }
            chat = AgentChatView(profile: profile, conversation: conversation)
        }
        if newTabIfRoom, chats.count < profile.settings.agentTabs {
            add(chat)
            select(chats.count - 1, focus: true)
        } else {
            replace(activeIndex, with: chat)
        }
        chat.scrollToBottom()
    }

    /// A tab showing the chat gets a new one instead.
    private func delete(_ id: String) {
        if let index = scheduledChats.firstIndex(where: { $0.id == id }) {
            let chat = scheduledChats.remove(at: index)
            chat.shutDown()
            chat.removeFromSuperview()
            refresh()
        }
        if let index = chats.firstIndex(where: { $0.id == id }) {
            let old = chats.remove(at: index)
            old.shutDown()
            old.removeFromSuperview()
            add(AgentChatView(profile: profile), at: index)
            select(activeIndex, focus: false)
        }
        profile.agentHistory.delete(id)
    }

    // MARK: Agent

    /// Picking another agent starts a new chat with it, unless the selected
    /// tab has no messages yet.
    @objc private func agentChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let kind = AgentChoice(rawValue: raw),
            kind != active.choice || kind != profile.providers.current
        else { return }
        let startOver = !active.isEmpty && kind != active.choice
        profile.providers.current = kind
        if startOver { newChat() } else { refresh() }
    }

    /// The CLIs, then the providers added in Settings.
    private func fillAgentPicker() {
        agentPicker.removeAllItems()
        for (index, choice) in profile.providers.all.enumerated() {
            if index == AgentKind.allCases.count { agentPicker.menu?.addItem(.separator()) }
            agentPicker.addItem(withTitle: profile.providers.displayName(choice))
            agentPicker.lastItem?.representedObject = choice.rawValue
            agentPicker.lastItem?.image = choice.logo(size: 16)
        }
    }

    /// A provider was added, renamed or removed in Settings.
    @objc private func providersChanged(_ notification: Notification) {
        fillAgentPicker()
        refresh()
        (chats + scheduledChats).forEach { $0.providersChanged() }
    }

    /// Settings changed the agent for new chats, which an empty tab shows.
    @objc private func currentAgentChanged(_ notification: Notification) {
        refresh()
    }

    // MARK: Sending

    #if DEBUG
    func stopForTesting() { active.stopForTesting() }

    func pasteAndSendForTesting(_ text: String) { active.pasteAndSendForTesting(text) }

    /// One of the tab bar's buttons, by name, for `ui.agentAction`.
    func performForTesting(_ action: String) {
        switch action {
        case "newChat": newChat()
        case "newTab": newTab()
        case "closeTab": closeTab(activeIndex)
        case "history": tabBar.historyForTesting()
        case "tools": active.toolsForTesting()
        case "model": active.modelForTesting()
        case "focus": window?.makeFirstResponder(input)
        case "enter": active.submitForTesting(direct: false)
        case "ctrlEnter": active.submitForTesting(direct: true)
        default:
            if action.hasPrefix("tab"), let index = Int(action.dropFirst(3)), chats.indices.contains(index - 1) {
                select(index - 1, focus: true)
            }
        }
    }

    /// Puts `text` in the selected chat's message field, as if typed.
    func setTextForTesting(_ text: String) {
        window?.makeFirstResponder(input)
        active.setTextForTesting(text)
    }
    #endif

    func send(_ text: String) {
        active.send(text)
    }

    // MARK: Scheduled runs

    func isChatBusy(_ id: String) -> Bool {
        (chats + scheduledChats).contains { $0.id == id && $0.isBusy }
    }

    /// Sends a scheduled prompt in a new chat in the background, taking no
    /// tab. Once its turn ends the chat leaves, unless opened in a tab by
    /// then; it stays in history. `completion` gets the chat's id and how
    /// its turn ended.
    func runScheduled(_ schedule: ScheduledPrompt, completion: @escaping (String, AgentRunOutcome) -> Void) -> String {
        let chat = AgentChatView(profile: profile, kind: schedule.choice, tools: schedule.tools, modelOptions: schedule.modelOptions)
        attach(chat)
        scheduledChats.append(chat)
        let id = chat.id
        chat.runScheduled(schedule) { [weak self, weak chat] outcome in
            completion(id, outcome)
            guard let self, let chat, let index = self.scheduledChats.firstIndex(of: chat) else { return }
            self.scheduledChats.remove(at: index)
            chat.shutDown()
            chat.removeFromSuperview()
            self.refresh()
        }
        refresh()
        return id
    }
}


// MARK: Header

/// Where the agent is at: a dot, pulsing while it works, and a short label.
private final class StatusPill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Theme.busyDot / 2
        label.font = .systemFont(ofSize: Theme.FontSize.caption)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [dot, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Theme.busyDot),
            dot.heightAnchor.constraint(equalToConstant: Theme.busyDot),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The dot's color is the only other sign of the state, so VoiceOver
        // reads the pill as one element whose label says it in words.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, busy: Bool) {
        label.stringValue = text
        isHidden = text.isEmpty
        toolTip = text
        setAccessibilityLabel("Agent status: \(text)")
        guard busy != self.busy else { return }
        self.busy = busy
        needsDisplay = true
        dot.layer?.removeAnimation(forKey: "pulse")
        if busy, !Theme.reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        dot.layer?.backgroundColor = (busy ? Theme.accentColor : Theme.success).layerColor
    }
}

// MARK: Empty state

/// What a new chat shows: what the agent can do, and a few things to ask.
final class AgentEmptyState: NSView {
    var onSuggestion: ((String) -> Void)?
    private var kind: AgentChoice?

    /// Names the agent, `name` being its name or its provider's.
    func show(_ kind: AgentChoice, name: String) {
        guard kind != self.kind || title.stringValue != "Ask \(name)" else { return }
        let changed = kind != self.kind
        self.kind = kind
        title.stringValue = "Ask \(name)"
        title.toolTip = title.stringValue
        if changed { badge.logo = kind.logo(size: 28) }
    }

    private let badge = SymbolBadge(symbol: "sparkles")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "It can read the page, click, type and open tabs for you. Type / for skills.")
    private static let subtitleWidth: CGFloat = 240

    private static let suggestions: [(symbol: String, text: String)] = [
        ("text.alignleft", "Summarize this page"),
        ("list.bullet", "List the key points"),
        ("magnifyingglass", "Find related pages"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: Theme.FontSize.title, weight: .semibold)
        title.alignment = .center
        // A long agent or provider name ends in an ellipsis in a narrow panel
        // rather than being cut mid-letter.
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitle.font = .systemFont(ofSize: Theme.FontSize.secondary)
        subtitle.textColor = Theme.secondaryText
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = Self.subtitleWidth

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 6
        for (symbol, text) in Self.suggestions {
            let button = SuggestionButton(symbol: symbol, title: text) { [weak self] in self?.onSuggestion?(text) }
            buttons.addArrangedSubview(button)
            // One width for all, so the column reads as a list.
            button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }

        let stack = NSStackView(views: [badge, title, subtitle, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: badge)
        stack.setCustomSpacing(18, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The subtitle wraps to the space there is, when the panel is narrower
    /// than its usual width. Set before the stack lays out, so it lays out once.
    override func layout() {
        let width = min(Self.subtitleWidth, bounds.width)
        if width > 0, subtitle.preferredMaxLayoutWidth != width { subtitle.preferredMaxLayoutWidth = width }
        super.layout()
    }
}

/// An SF Symbol on a soft accent-colored circle, or a logo on a plain one.
private final class SymbolBadge: NSView {
    /// Shown instead of the symbol, in its own colors.
    var logo: NSImage? {
        didSet {
            image.image = logo ?? symbol
            image.contentTintColor = logo == nil ? Theme.accentColor : nil
            needsDisplay = true
        }
    }

    private let symbol: NSImage
    private let image: NSImageView
    private static let side: CGFloat = 48

    init(symbol: String) {
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))!
        image = NSImageView(image: self.symbol)
        super.init(frame: .zero)
        wantsLayer = true
        image.contentTintColor = Theme.accentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Round, at any size.
        layer?.cornerRadius = Self.side / 2
        let color = logo == nil ? Theme.accent(Theme.Accent.soft) : Theme.fill(Theme.Fill.rest)
        layer?.backgroundColor = color.layerColor
    }
}

/// A rounded, lightly filled button with an icon and a prompt, which
/// highlights on hover.
private final class SuggestionButton: NSView {
    private let action: () -> Void
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!)
        icon.contentTintColor = Theme.secondaryText
        // The symbols differ in width, so each sits centered in a slot of one
        // width and the prompts start at one x.
        icon.imageAlignment = .alignCenter
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.plate
        layer?.cornerCurve = .continuous
        let alpha = isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.hairline.layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: Composer

/// The message field: a rounded card with the text across its full width on
/// top, growing with what is typed up to a few lines, and a row of controls
/// along its bottom: the add button, the chat's model and tools, and the
/// send/stop button. Attached images show above the text. Images pasted or
/// dropped on it go to `onImages`.
final class Composer: NSView {
    let textView = PlaceholderTextView()
    let sendButton = SendButton()
    /// Opens a menu of things to add: images, or a message sent before.
    let addButton = Theme.iconButton("plus", label: "Add")
    /// Names the chat's model and opens its options.
    let modelButton = ComposerChip()
    /// Tinted while any built-in tool is on, and opens their menu.
    let toolsButton = Theme.iconButton("wrench.and.screwdriver", label: "Tools", size: Theme.Symbol.row)
    var onImages: (([NSImage]) -> Void)?
    var onOpenImage: ((Int) -> Void)?
    private let undo = UndoManager()
    private let scrollView = NSScrollView()
    private let thumbnails = ThumbnailGrid(side: 48, alignment: .leading)
    private var textHeight: NSLayoutConstraint!
    private var textBelowTop: NSLayoutConstraint!
    private var textBelowThumbnails: NSLayoutConstraint!
    /// Whether the field holds nothing but whitespace, worked out once per
    /// change rather than each time the chat asks.
    private var isBlank = true
    /// Whether the placeholder was showing as of the last change.
    private var hadNoText = true
    private var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }

    var attachments: [AgentAttachment] = [] {
        didSet {
            thumbnails.images = attachments.map(\.image)
            thumbnails.isHidden = attachments.isEmpty
            textBelowTop.isActive = attachments.isEmpty
            textBelowThumbnails.isActive = !attachments.isEmpty
            updateSendButton()
        }
    }

    private static let font = NSFont.systemFont(ofSize: Theme.FontSize.body)
    private static let maxLines: CGFloat = 10
    /// The card's inner margins: the text's from the edges, the controls'
    /// from the corners.
    private static let textInset: CGFloat = 12
    private static let controlInset: CGFloat = 6

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            // Typing undo steps refer to the old text.
            undo.removeAllActions()
            textChanged()
        }
    }

    override var undoManager: UndoManager? { undo }

    var placeholder = "" {
        didSet { updatePlaceholder() }
    }

    /// Drawn instead of `placeholder` when that doesn't fit the field.
    var shortPlaceholder = "" {
        didSet { updatePlaceholder() }
    }

    /// While a turn runs, the hint says that what is written now waits.
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            updateSendButton()
            updatePlaceholder()
        }
    }

    private func updatePlaceholder() {
        textView.placeholder = isBusy ? "Queue a follow-up…" : placeholder
        textView.shortPlaceholder = isBusy ? "Follow up…" : shortPlaceholder
    }

    /// Messages wait to be sent, which an empty field can send.
    var hasQueued = false {
        didSet { if hasQueued != oldValue { updateSendButton() } }
    }

    /// Whether nothing is written or attached.
    var isEmpty: Bool { isBlank && attachments.isEmpty }

    /// Shows the chat's model, `summary` in full in the tooltip, and its
    /// tools. A model or tools other than the CLI's own read stronger.
    func showOptions(model title: String, summary: String, isDefault: Bool, tools: [AgentTool]) {
        modelButton.title = title
        modelButton.isEmphasized = !isDefault
        modelButton.toolTip = "Model: " + summary
        modelButton.setAccessibilityValue(summary)
        toolsButton.contentTintColor = tools.isEmpty ? Theme.secondaryText : Theme.accentColor
        toolsButton.toolTip = tools.isEmpty
            ? "Tools: browser only"
            : "Tools: browser, " + tools.map { $0.displayName.lowercased() }.joined(separator: ", ")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        textView.font = Self.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onFocusChange = { [weak self] in self?.needsDisplay = true }
        textView.onPasteboardImages = { [weak self] pasteboard in self?.takeImages(from: pasteboard) ?? false }
        textView.imageDropTarget = self
        // The placeholder is drawn by hand, so VoiceOver gets it, and a
        // name for the field, from here.
        textView.setAccessibilityLabel("Message")
        registerForDraggedTypes(AgentAttachment.pasteboardTypes)

        thumbnails.isHidden = true
        thumbnails.onOpen = { [weak self] index in self?.onOpenImage?(index) }
        thumbnails.onRemove = { [weak self] index in
            guard let self else { return }
            let removed = self.attachments.remove(at: index)
            try? FileManager.default.removeItem(at: removed.url)
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        updateSendButton()

        // The model's name truncates before the row clips any button.
        modelButton.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let leading = NSStackView(views: [addButton, modelButton, toolsButton])
        leading.spacing = 2
        leading.setClippingResistancePriority(.defaultLow, for: .horizontal)

        for view in [thumbnails, scrollView, leading, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        textBelowTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 11)
        textBelowThumbnails = scrollView.topAnchor.constraint(equalTo: thumbnails.bottomAnchor, constant: 10)
        NSLayoutConstraint.activate([
            thumbnails.topAnchor.constraint(equalTo: topAnchor, constant: Self.textInset),
            thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            thumbnails.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInset),
            textBelowTop,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textInset),
            textHeight,

            sendButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.controlInset),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.controlInset),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.controlInset),
            leading.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    /// Whether the insertion point is on the text's first line, as laid
    /// out, where Up goes to an older message.
    var caretOnFirstLine: Bool {
        let string = textView.string as NSString
        let location = textView.selectedRange().location
        guard location > 0, let layoutManager = textView.layoutManager else { return true }
        // After a final newline, the caret is on a line of its own.
        if location == string.length, string.character(at: location - 1) == 0x0A { return false }
        return lineRange(of: min(location, string.length - 1), in: layoutManager).location == 0
    }

    /// Whether the end of the selection is on the text's last line, as laid
    /// out, where Down goes to a newer message.
    var caretOnLastLine: Bool {
        let string = textView.string as NSString
        let location = NSMaxRange(textView.selectedRange())
        guard location < string.length, let layoutManager = textView.layoutManager else { return true }
        // A final newline starts a line after the last character's.
        if string.character(at: string.length - 1) == 0x0A { return false }
        return NSMaxRange(lineRange(of: location, in: layoutManager)) >= layoutManager.numberOfGlyphs
    }

    /// The glyphs on the laid-out line that holds `character`.
    private func lineRange(of character: Int, in layoutManager: NSLayoutManager) -> NSRange {
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var range = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        return range
    }

    func textChanged() {
        let string = textView.string
        // Stops at the first character that isn't whitespace, usually the first.
        isBlank = !string.contains { !$0.isWhitespace }
        updateSendButton()
        // The placeholder comes and goes with the text.
        if string.isEmpty != hadNoText {
            hadNoText = string.isEmpty
            textView.needsDisplay = true
        }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        // Only as far down as the field can grow: past that it scrolls, and
        // the rest is laid out as it shows.
        let tallest = Self.lineHeight * Self.maxLines
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: tallest + 1), in: container)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(Self.lineHeight, used), tallest).rounded(.up)
        if textHeight.constant != height { textHeight.constant = height }
    }

    private func updateSendButton() {
        let empty = isEmpty
        // While a turn runs, a written message is queued instead.
        if isBusy && empty {
            sendButton.show(.stop, toolTip: "Stop (⎋)")
        } else {
            sendButton.show(.send, toolTip: isBusy ? "Queue (↩) · Stop and Send (⌃↩)" : "Send (↩)")
        }
        sendButton.isEnabled = isBusy || !empty || hasQueued
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let focused = window?.firstResponder === textView
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The same corners as the skill picker that opens above it.
        layer.cornerRadius = Theme.Radius.plate
        layer.cornerCurve = .continuous
        // See-through over the panel's material, unless Reduce Transparency is on.
        let background: NSColor = isDropTarget ? Theme.accent(0.08)
            : Theme.surface.dynamic(alpha: Theme.reduceTransparency ? 1 : dark ? 0.75 : 0.92)
        let border: NSColor = isDropTarget ? Theme.accentColor
            : focused ? Theme.accent(Theme.Accent.outline) : Theme.hairline
        // A soft lift off the panel, which focus tints with the accent.
        let shadow: NSColor = focused || isDropTarget ? Theme.accentColor : .black
        let shadowOpacity: Float = focused || isDropTarget ? (dark ? 0.35 : 0.22) : (dark ? 0.25 : 0.07)
        withEasing(Theme.Duration.quick) {
            layer.backgroundColor = background.layerColor
            layer.borderWidth = isDropTarget ? 2 : Theme.hairlineWidth
            layer.borderColor = border.layerColor
            layer.shadowColor = shadow.layerColor
            layer.shadowOpacity = shadowOpacity
            layer.shadowRadius = focused || isDropTarget ? 5 : 8
            layer.shadowOffset = focused || isDropTarget ? .zero : CGSize(width: 0, height: -2)
        }
        // A path keeps the shadow off the offscreen pass AppKit would
        // otherwise render the card's contents in to find its outline.
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.plate, cornerHeight: Theme.Radius.plate, transform: nil)
        layer.masksToBounds = false
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.plate, cornerHeight: Theme.Radius.plate, transform: nil)
    }

    /// Clicks anywhere in the card that isn't a control go to the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    /// Hands the pasteboard's images to `onImages`, and returns false if it
    /// has none, so it is pasted as text.
    private func takeImages(from pasteboard: NSPasteboard) -> Bool {
        guard AgentAttachment.canRead(pasteboard) else { return false }
        onImages?(AgentAttachment.images(on: pasteboard))
        return true
    }

    // MARK: Dropping images

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget = AgentAttachment.canRead(sender.draggingPasteboard)
        return isDropTarget ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        return takeImages(from: sender.draggingPasteboard)
    }
}

/// The composer's send button: an arrow on a disc of the accent color, which
/// greys out with nothing to send, and a square on a disc of the text color
/// while a turn can be stopped. The disc eases between states and dips under
/// a press.
final class SendButton: NSButton {
    enum Mode { case send, stop }

    static let side: CGFloat = 28

    private(set) var mode = Mode.send
    private let disc = CALayer()
    private let glyph = CALayer()
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        layer?.addSublayer(disc)
        disc.addSublayer(glyph)
        disc.cornerCurve = .circular
        glyph.contentsGravity = .center
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setAccessibilityLabel("Send")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `mode`, with `toolTip`, changing nothing that is already so.
    func show(_ mode: Mode, toolTip: String) {
        if self.toolTip != toolTip { self.toolTip = toolTip }
        guard mode != self.mode else { return }
        self.mode = mode
        setAccessibilityLabel(mode == .stop ? "Stop" : "Send")
        needsDisplay = true
    }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let side = Self.side
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
        glyph.frame = disc.bounds

        let fill: NSColor
        let ink: NSColor
        switch (mode, isEnabled) {
        case (.stop, _):
            fill = Theme.text
            ink = Theme.chrome
        case (.send, true):
            fill = Theme.accentFill
            ink = Theme.accentFillText
        case (.send, false):
            fill = Theme.fill(Theme.Fill.pressed)
            ink = Theme.text.dynamic(alpha: 0.45)
        }
        // Hover and press redraw often, the glyph only per state and appearance.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(mode)-\(isEnabled)-\(dark)-\(Settings.theme.rawValue)"
        var image = Self.glyphs[key]
        if image == nil {
            // A fixed color, since the image would resolve a dynamic one
            // whenever, and in whichever appearance, it is drawn.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                image = Self.glyph(for: mode, color: NSColor(cgColor: ink.cgColor) ?? ink)
            }
            Self.glyphs[key] = image
        }
        let scale: CGFloat = isHighlighted && isEnabled ? 0.9 : 1
        withEasing(Theme.Duration.quick) {
            disc.backgroundColor = fill.layerColor
            disc.opacity = isHovered && isEnabled && !isHighlighted ? 0.88 : 1
            disc.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        glyph.contents = image
        glyph.contentsScale = window?.backingScaleFactor ?? 2
    }

    private static var glyphs: [String: NSImage] = [:]

    private static func glyph(for mode: Mode, color: NSColor) -> NSImage? {
        let name = mode == .stop ? "stop.fill" : "arrow.up"
        let size: CGFloat = mode == .stop ? 10 : 13
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    private var hoverArea: NSTrackingArea?

    // Only its own area is replaced: the others are AppKit's.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseExited(with: event) }
        isHovered = false
    }
}

/// A borderless text button with a small chevron after it, which opens a
/// menu: the composer's model. Plain secondary text at rest, stronger when
/// `isEmphasized`, with the hover plate of the other bar buttons.
final class ComposerChip: HoverButton {
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { updateTitle() } }
    }

    override var title: String {
        didSet { if title != oldValue { updateTitle() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .accessoryBarAction
        image = Theme.symbol("chevron.down", size: 8, weight: .semibold)
        imagePosition = .imageTrailing
        imageHugsTitle = true
        lineBreakMode = .byTruncatingTail
        cell?.lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Theme.ButtonSize.bar).isActive = true
        setAccessibilityLabel("Model")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        let color: NSColor = isEmphasized ? Theme.text : Theme.secondaryText
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.secondary, weight: .medium),
            .foregroundColor: color,
        ])
    }

    /// Room on each side for the plate.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        return size
    }
}

// MARK: Queued messages

/// The messages written while a turn runs, above the tab bar: one row each,
/// which a click takes back into the field and its close button removes.
/// Empty, it takes no room.
final class QueuedMessagesView: NSView {
    var onEdit: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onSendNow: (() -> Void)?

    private let stack = NSStackView()
    private let header = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let sendNowButton = NSButton(title: "Send Now", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        headerLabel.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        headerLabel.textColor = Theme.secondaryText
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sendNowButton.bezelStyle = .accessoryBarAction
        sendNowButton.controlSize = .small
        sendNowButton.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        sendNowButton.target = self
        sendNowButton.action = #selector(sendNow(_:))
        header.orientation = .horizontal
        header.spacing = 6
        // The header's text starts where the rows' text does.
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
        header.setViews([headerLabel, sendNowButton], in: .leading)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Each message's text and how many images it has.
    func show(_ messages: [(text: String, images: Int)], paused: Bool) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        // Room from the transcript only while there is something to show.
        stack.edgeInsets = NSEdgeInsets(top: messages.isEmpty ? 0 : 6, left: 0, bottom: 0, right: 0)
        guard !messages.isEmpty else { return }
        headerLabel.stringValue = paused ? "Queued · paused" : "Queued · sends when this turn finishes"
        sendNowButton.isHidden = !paused
        stack.addArrangedSubview(header)
        for (index, message) in messages.enumerated() {
            let row = QueuedMessageRow(text: message.text, images: message.images)
            row.onEdit = { [weak self] in self?.onEdit?(index) }
            row.onRemove = { [weak self] in self?.onRemove?(index) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func sendNow(_ sender: Any?) { onSendNow?() }
}

/// A queued message's first line, with its image count and a close button.
private final class QueuedMessageRow: NSView {
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?

    private let closeButton = HoverButton()
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(text: String, images: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous

        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let imageNote = images == 0 ? nil : images == 1 ? "1 image" : "\(images) images"
        let label = NSTextField(labelWithString: firstLine.isEmpty ? imageNote ?? "" : firstLine)
        label.font = .systemFont(ofSize: Theme.FontSize.secondary)
        label.textColor = firstLine.isEmpty ? Theme.secondaryText : Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = NSTextField(labelWithString: firstLine.isEmpty ? "" : imageNote ?? "")
        count.font = .systemFont(ofSize: Theme.FontSize.caption)
        count.textColor = Theme.secondaryText
        count.isHidden = count.stringValue.isEmpty

        closeButton.image = Theme.closeImage(size: 8, label: "Remove from Queue")
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = Theme.secondaryText
        closeButton.toolTip = "Remove from Queue"
        closeButton.plateRadius = 8
        closeButton.target = self
        closeButton.action = #selector(remove(_:))

        for view in [label, count, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: count.trailingAnchor, constant: 4),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        toolTip = "Click to edit"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Queued: " + (firstLine.isEmpty ? imageNote ?? "" : firstLine))
        setAccessibilityHelp("Takes the message back into the field to edit")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let alpha = isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.hairline.layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onEdit?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onEdit?()
        return true
    }

    @objc private func remove(_ sender: Any?) { onRemove?() }
}

/// The images Quick Look shows for the panel.
final class QuickLookItems: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []
    var index = 0

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

/// A text view that shows a grey hint while empty and reports focus changes.
/// Images pasted into it go to `onPasteboardImages`, and images dragged onto
/// it go to `imageDropTarget`.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet {
            needsDisplay = true
            setAccessibilityPlaceholderValue(placeholder)
        }
    }
    /// Drawn when `placeholder` would truncate. VoiceOver still reads the
    /// full one.
    var shortPlaceholder = "" {
        didSet { needsDisplay = true }
    }
    var onFocusChange: (() -> Void)?
    /// Sees each key first, and returns true for one it handled.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Takes the pasteboard's images, returning false if it has none.
    var onPasteboardImages: ((NSPasteboard) -> Bool)?
    weak var imageDropTarget: NSView?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func paste(_ sender: Any?) {
        if onPasteboardImages?(.general) != true { super.paste(sender) }
    }

    /// Paste is on for an image, which plain text can't take.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteboardImages != nil, AgentAttachment.canRead(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + AgentAttachment.pasteboardTypes
    }

    private func dropsImages(_ sender: (any NSDraggingInfo)?) -> Bool {
        guard let sender, imageDropTarget != nil else { return false }
        return AgentAttachment.canRead(sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropsImages(sender) ? imageDropTarget!.draggingEntered(sender) : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropsImages(sender) ? imageDropTarget!.draggingUpdated(sender) : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if dropsImages(sender) { imageDropTarget!.draggingExited(sender) } else { super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropsImages(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropsImages(sender) ? imageDropTarget!.performDragOperation(sender) : super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: Theme.FontSize.body),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        let available = bounds.width - origin.x - textContainerOrigin.x - padding
        var text = NSAttributedString(string: placeholder, attributes: attributes)
        // A shorter hint whole reads better than the long one cut off.
        if !shortPlaceholder.isEmpty, ceil(text.size().width) > available {
            text = NSAttributedString(string: shortPlaceholder, attributes: attributes)
        }
        text.draw(with: NSRect(origin: origin, size: NSSize(width: available, height: bounds.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The hint that fits depends on the width, so it is drawn again on a resize.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, string.isEmpty, !placeholder.isEmpty { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }
}
