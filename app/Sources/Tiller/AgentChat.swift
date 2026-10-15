import AppKit
import Quartz

/// One chat in the agent panel: its transcript, its message field and the
/// agent process behind it. Each tab of the panel holds one. A chat is saved
/// to history with its first message, and one opened from history continues
/// the CLI's saved session on the next message.
final class AgentChatView: NSView, NSTextViewDelegate {
    /// The selected tab, described for the agent at the start of each message.
    var context: (() -> String)?
    var commandContext: (() -> [String: Any])?
    /// Called when the title, status or agent changes, or a turn starts or ends.
    var onChange: (() -> Void)?
    /// Get the message field's model or tools button, to show the menu from.
    var onModel: ((NSView) -> Void)?
    var onTools: ((NSView) -> Void)?

    let id: String
    /// Nil until the first message.
    private(set) var conversation: AgentConversation?
    private(set) var statusText = ""
    private(set) var statusBusy = false

    /// The message being written.
    var input: NSView { composer.textView }
    var isEmpty: Bool { conversation == nil }
    var isBusy: Bool { lookingUpAgent || session?.isBusy == true }
    /// Set while the agent's CLI is looked up in the background before the
    /// first message goes, which counts as working.
    private var lookingUpAgent = false
    /// Bumped by every lookup and by stopping one, so a lookup stopped and
    /// followed by another can't send its message when it returns.
    private var agentLookup = 0
    /// A new chat uses the agent picked for new chats until its first
    /// message, unless it was made for another.
    var choice: AgentChoice { conversation?.choice ?? presetKind ?? profile.providers.current }
    var kind: AgentKind { choice.kind }
    var title: String { conversation?.title ?? "New Chat" }
    /// The built-in tools this chat allows. A new chat starts with Settings'.
    private(set) var tools: [AgentTool]
    /// The model, effort, context and fast mode this chat runs with. A new
    /// chat follows Settings' for its agent until one is picked for it.
    var modelOptions: AgentModelOptions {
        (conversation?.modelOptions ?? pickedOptions ?? profile.settings.agentModelOptions(for: choice)).supported(by: choice)
    }
    /// Picked for a new chat before its first message.
    private var pickedOptions: AgentModelOptions?

    /// Where the panel puts its tab bar, between the transcript and the field.
    let tabBarHost = NSView()

    private let separator = NSBox()
    private let transcript = TranscriptView()
    private let scrollView = NSScrollView()
    /// Fades the transcript out under the header and above the tab bar, so a
    /// line is never sliced at either edge. A mask rather than a strip of the
    /// background over the text, since what shows behind the panel is the
    /// window's glass or tint, which no one color matches.
    private let edgeFade = EdgeFadeMask()
    /// Room above the first message and below the last, inside the scroll
    /// view, so neither sits on the fades.
    private static let insets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
    private let emptyState = AgentEmptyState()
    private let composer = Composer()
    private lazy var skillCompletion = SkillCompletion(textView: composer.textView) { [weak self] in
        self?.availableCompletions ?? []
    }
    private let promptSearch = PromptSearch()
    /// Up and Down's place among the sent messages, nil while the field
    /// holds what is being written.
    private var recalled: (prompts: [String], index: Int)?
    /// What was in the field when Up first went back, which Down past the
    /// newest message brings back.
    private var draft = ""
    /// The skills the running agent said it loaded. Until then, `/` offers
    /// what Tiller finds on disk.
    private var loadedSkills: [AgentSkill]?
    /// The agent a new chat was made for, such as a scheduled run's.
    private let presetKind: AgentChoice?
    /// Called once when a scheduled run's turn ends, with how it went.
    private var runCompletion: ((AgentRunOutcome) -> Void)?

    private var session: AgentSession?
    /// Set while a session resumes a saved conversation and hasn't started yet.
    private var resuming = false
    private var records: [AgentRecord] = []
    /// The text block Claude Code is streaming into, until the complete block arrives.
    private var liveText: MarkdownMessageView?
    private var liveTextBuffer = ""
    /// The turn's last text so far and when it came: it gets Copy and the
    /// time once the turn ends.
    private var turnText: (view: MarkdownMessageView, date: Date)?
    /// The newest response, whose Copy and time stay shown.
    private var pinnedResponse: MarkdownMessageView?
    /// Streamed text is drawn at most this often, so a fast stream doesn't
    /// re-render the whole block for every few characters.
    private var liveTextRenderPending = false
    private static let liveTextInterval = 0.05
    /// Streamed text that came while the chat was hidden, in a background
    /// tab or a closed panel. It is drawn once, when the chat shows again.
    private var liveTextStale = false
    /// Running tool calls: their rows and where they are in `records`.
    private var toolRows: [String: (row: ToolRowView, record: Int)] = [:]
    /// run_task calls under way, by goal, which is how the window's reports
    /// of a run find them.
    private var jevRows: [String: ToolRowView] = [:]
    /// Output lines of running commands not yet drawn, by call id. A noisy
    /// command prints far more often than a row is worth redrawing.
    private var pendingProgress: [String: String] = [:]
    private static let progressInterval = 0.2
    /// The reasoning under way: when it started and its text so far.
    private var reasoningStarted: Date?
    private var reasoningText = ""
    private let quickLook = QuickLookItems()
    /// Brings the newest message back into view after scrolling up.
    private let scrollDownButton = ScrollDownButton()
    private let queueView = QueuedMessagesView()

    private typealias Message = (text: String, images: [AgentAttachment])
    /// Messages written while a turn runs. They go together as one message
    /// once it finishes, except that one starting with `/` goes on its own,
    /// since a skill is called only at the very start.
    private var queued: [Message] = [] {
        didSet { updateQueue() }
    }
    /// Set when a turn ends without finishing, by Stop, an error or the agent
    /// exiting, so the queue waits for Enter or Send Now.
    private var queuePaused = false {
        didSet { updateQueue() }
    }
    /// Ctrl+Enter's message, sent ahead of the queue once the turn it
    /// interrupted has ended.
    private var pendingDirect: Message?

    private var folder: URL { profile.agentHistory.folder(for: id) }
    private let profile: ProfileContext
    /// A saved chat opens at its newest message once it has a size.
    private var pendingScrollToBottom = false

    /// Where the saved transcript is: still in its file, on its way from
    /// disk, or drawn. A saved chat waits until it is first shown or written
    /// to, so a launch with several tabs of long chats doesn't build them all
    /// behind a hidden panel.
    private enum LoadState {
        case unloaded
        /// Numbered, so a read that was overtaken is dropped when it lands.
        case loading(Int)
        case loaded
    }
    private var loadState: LoadState
    private var loadCount = 0
    private var recordsLoaded: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    /// A new chat, or a saved one with its transcript. A new chat can be
    /// given its agent, tools and model options instead of those in Settings.
    init(
        profile: ProfileContext, conversation: AgentConversation? = nil, kind: AgentChoice? = nil,
        tools: [AgentTool]? = nil, modelOptions: AgentModelOptions? = nil
    ) {
        self.profile = profile
        id = conversation?.id ?? UUID().uuidString
        self.conversation = conversation
        presetKind = conversation == nil ? kind : nil
        self.tools = conversation?.tools ?? tools ?? profile.settings.agentTools
        pickedOptions = conversation == nil ? modelOptions : nil
        loadState = conversation == nil ? .loaded : .unloaded
        super.init(frame: .zero)
        build()
        showIdle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentAgentChanged(_:)), name: .agentKindDidChange, object: profile.providers
        )
    }

    /// Reads and draws the saved transcript, once. The file and the
    /// thumbnails of its images are read off the main thread, since a long
    /// chat with screenshots would hold the tab switch up. `now` reads them
    /// here instead, for a send that is about to add to them.
    func loadIfNeeded(now: Bool = false) {
        switch loadState {
        case .loaded: return
        case .loading where !now: return
        case .loading, .unloaded: break
        }
        let folder = folder
        // The newest records may still be on their way to disk.
        let unwritten = profile.agentHistory.unwrittenRecords(for: id)
        if now {
            let records = unwritten ?? AgentHistoryStore.readRecords(in: folder)
            finishLoading(records, thumbnails: Self.thumbnails(for: records, in: folder))
            return
        }
        loadCount += 1
        let count = loadCount
        loadState = .loading(count)
        Task.detached(priority: .userInitiated) { [weak self] in
            let records = unwritten ?? AgentHistoryStore.readRecords(in: folder)
            let thumbnails = Self.thumbnails(for: records, in: folder)
            await MainActor.run {
                guard let self, case .loading(count) = self.loadState else { return }
                self.finishLoading(records, thumbnails: thumbnails)
            }
        }
    }

    /// Thumbnails for every image a transcript names, by file name. Read
    /// from the files, not the whole images: a saved chat can hold a dozen
    /// screenshots.
    nonisolated private static func thumbnails(for records: [AgentRecord], in folder: URL) -> Thumbnails {
        var images: [String: NSImage] = [:]
        for case .user(_, let names) in records {
            for name in names where images[name] == nil {
                images[name] = AgentAttachment.thumbnail(at: folder.appendingPathComponent(name), side: 128)
            }
        }
        return Thumbnails(images: images)
    }

    /// Images made on a background thread and only used on the main one
    /// once they are handed over.
    private struct Thumbnails: @unchecked Sendable {
        let images: [String: NSImage]
    }

    private func finishLoading(_ records: [AgentRecord], thumbnails: Thumbnails) {
        loadState = .loaded
        self.records = records
        // Each turn's last text gets Copy and its time: a turn ends at the
        // next message sent.
        var response: (view: MarkdownMessageView, date: Date?)?
        for record in records {
            if case .user = record, let ended = response {
                ended.view.showActions(date: ended.date)
                response = nil
            }
            let row = show(record, thumbnails: thumbnails)
            if case .text(_, let date) = record, let view = row as? MarkdownMessageView { response = (view, date) }
        }
        if let response { showResponseActions(response.view, date: response.date) }
        transcript.closeToolGroup()
        pendingScrollToBottom = !records.isEmpty
        showIdle()
        if pendingScrollToBottom { needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Ends the agent process, keeping what it said so far. A chat that was
    /// never sent loses its images. Called when the tab closes or the window does.
    func shutDown() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().dataSource === quickLook {
            QLPreviewPanel.shared().orderOut(nil)
        }
        if isBusy {
            keepLiveText()
            addNote("Stopped")
        }
        finishRun(.stopped)
        finishToolRows()
        transcript.hideThinking()
        transcript.closeToolGroup()
        endSession()
        let unsent = composer.attachments + queued.flatMap(\.images) + (pendingDirect?.images ?? [])
        for attachment in unsent { try? FileManager.default.removeItem(at: attachment.url) }
        composer.attachments = []
        queued = []
        queuePaused = false
        pendingDirect = nil
        profile.agentHistory.discardUnsaved(id)
    }

    private func endSession() {
        lookingUpAgent = false
        agentLookup += 1
        session?.stop()
        session = nil
        resuming = false
        loadedSkills = nil
    }

    // MARK: Layout

    private func build() {
        separator.boxType = .separator
        separator.alphaValue = 0

        scrollView.documentView = transcript
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Legacy scrollers (a mouse attached) take width when they appear, and
        // the transcript rewraps to fit; near one screen tall that flips until
        // AppKit gives up on layout. AppKit resets the style when the system
        // preference changes, so it is set again then.
        scrollView.scrollerStyle = .overlay
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleChanged(_:)), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = Self.insets
        // Shows the rule at the top only once the transcript scrolls under it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(transcriptScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(self, selector: #selector(jevRunChanged(_:)), name: .jevRunDidChange, object: nil)

        emptyState.onSuggestion = { [weak self] text in self?.send(text) }

        composer.textView.delegate = self
        composer.sendButton.target = self
        composer.sendButton.action = #selector(sendOrStop(_:))
        composer.addButton.target = self
        composer.addButton.action = #selector(showAddMenu(_:))
        composer.modelButton.target = self
        composer.modelButton.action = #selector(showModel(_:))
        composer.toolsButton.target = self
        composer.toolsButton.action = #selector(showTools(_:))
        composer.textView.onKeyDown = { [weak self] event in
            guard let self, PromptSearch.isSearchKey(event) else { return false }
            self.searchPrompts()
            return true
        }
        promptSearch.onPick = { [weak self] text in self?.recall(text, focus: true) }
        promptSearch.onCancel = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.composer.textView)
        }
        composer.onImages = { [weak self] images in self?.attach(images) }
        composer.onOpenImage = { [weak self] index in
            guard let self else { return }
            self.preview(self.composer.attachments.map(\.url), at: index)
        }

        scrollDownButton.target = self
        scrollDownButton.action = #selector(scrollDown(_:))

        queueView.onEdit = { [weak self] index in self?.editQueued(at: index) }
        queueView.onRemove = { [weak self] index in self?.removeQueued(at: index) }
        queueView.onSendNow = { [weak self] in self?.submit() }

        scrollView.wantsLayer = true
        scrollView.layer?.mask = edgeFade

        for view in [scrollView, separator, emptyState, scrollDownButton, queueView, tabBarHost, composer, skillCompletion.picker, promptSearch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: queueView.topAnchor),

            transcript.topAnchor.constraint(equalTo: clip.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            // Less the insets, so a short transcript doesn't scroll.
            transcript.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor, constant: -(Self.insets.top + Self.insets.bottom)),

            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            scrollDownButton.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            scrollDownButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -10),

            queueView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            queueView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            queueView.bottomAnchor.constraint(equalTo: tabBarHost.topAnchor, constant: -4),

            tabBarHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabBarHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabBarHost.heightAnchor.constraint(equalToConstant: AgentTabBar.height),
            tabBarHost.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            skillCompletion.picker.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            skillCompletion.picker.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            skillCompletion.picker.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),

            promptSearch.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            promptSearch.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            promptSearch.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
        ])
    }

    override func layout() {
        super.layout()
        edgeFade.fit(scrollView.bounds)
        guard bounds.height > 0, !isHiddenOrHasHiddenAncestor else { return }
        loadIfNeeded()
        guard pendingScrollToBottom else { return }
        pendingScrollToBottom = false
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scrollToBottom() } }
    }

    /// Shown for the first time, or the panel came back: draw the saved chat.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if !recordsLoaded || pendingScrollToBottom { needsLayout = true }
        if liveTextStale { scheduleLiveTextRender() }
    }

    /// The scroll view resets its own style on the same notification, so this
    /// waits for that to happen first.
    @objc private func scrollerStyleChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scrollView.scrollerStyle = .overlay } }
    }

    @objc private func transcriptScrolled(_ notification: Notification) {
        // At the top the clip's origin sits at minus the top inset.
        let scrolled = scrollView.contentView.bounds.minY > 1 - Self.insets.top
        if (separator.alphaValue > 0) != scrolled {
            withEasing(Theme.Duration.quick) { separator.animator().alphaValue = scrolled ? 1 : 0 }
        }
        updateScrollDownButton()
    }

    /// The button shows once the newest message is more than a screen's
    /// worth out of view.
    private func updateScrollDownButton() {
        let clip = scrollView.contentView.bounds
        let away = transcript.frame.height - (clip.maxY - Self.insets.bottom)
        scrollDownButton.setShown(away > max(80, clip.height * 0.5))
    }

    @objc private func scrollDown(_ sender: Any?) {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = bottomOffset
        if Theme.reduceMotion {
            clip.scroll(to: NSPoint(x: 0, y: y))
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.panel
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// A provider's name may have changed.
    func providersChanged() {
        if session == nil { showIdle() }
    }

    /// Settings or the picker changed the agent for new chats.
    @objc private func currentAgentChanged(_ notification: Notification) {
        // Options picked for one agent don't carry over to another.
        if conversation == nil, presetKind == nil { pickedOptions = nil }
        if session == nil { showIdle() }
    }

    // MARK: Sending

    #if DEBUG
    func stopForTesting() { stopTurn() }

    /// Enter, or with `direct` Ctrl+Enter, in the message field.
    func submitForTesting(direct: Bool) { submit(direct: direct, allowsCommands: false) }

    /// Replaces the message field's text, as typing would, so the skill
    /// picker follows it.
    func setTextForTesting(_ text: String) {
        composer.text = text
        skillCompletion.update()
    }

    /// Pastes the clipboard into the composer twice, as Cmd+V would, then
    /// sends `text` with it after a few seconds.
    func pasteAndSendForTesting(_ text: String) {
        composer.textView.paste(nil)
        composer.textView.paste(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                self?.composer.text = text
                self?.submit(allowsCommands: false)
            }
        }
    }
    #endif

    /// While a turn runs, the button queues what is written, or stops the
    /// turn when nothing is.
    @objc private func sendOrStop(_ sender: Any?) {
        if isBusy, composerIsEmpty {
            stopTurn()
        } else {
            submit(allowsCommands: true)
        }
    }

    private func stopTurn() {
        guard isBusy else { return }
        if lookingUpAgent {
            // Nothing has started yet, so there is nothing to interrupt; the
            // turn ends here as a stopped one does.
            lookingUpAgent = false
            agentLookup += 1
            transcript.hideThinking()
            setBusy(false)
            showIdle()
            finishRun(.stopped)
            turnEnded(finished: false)
            return
        }
        session?.interrupt()
        // Antigravity CLI and Grok Build have already stopped.
        if isBusy { setStatus("Stopping…", busy: true) }
    }

    private var composerIsEmpty: Bool { composer.isEmpty }

    /// Enter sends, or queues while a turn runs. Ctrl+Enter stops the turn
    /// and sends right away. Option+Enter or Shift+Enter adds a line. Escape
    /// stops a running turn. Up on the first line and Down on the last go
    /// through the messages sent before.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if skillCompletion.handle(selector) { return true }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            return stepThroughSent(older: true)
        case #selector(NSResponder.moveDown(_:)):
            return stepThroughSent(older: false)
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.option) || flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                submit(allowsCommands: true)
            }
            return true
        // What Ctrl+Return is bound to.
        case #selector(NSResponder.insertLineBreak(_:)):
            submit(direct: true, allowsCommands: true)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard isBusy else { return false }
            stopTurn()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        // An edited message becomes what is being written.
        recalled = nil
        composer.textChanged()
        skillCompletion.update()
    }

    // MARK: Skills

    /// What `/` can call in this chat.
    private var availableSkills: [AgentSkill] {
        loadedSkills ?? AgentSkillCatalog.skills(for: kind, library: profile.skills)
    }

    private var availableCompletions: [AgentSkill] {
        let commands = profile.settings.agentCommands
        let names = Set(commands.map(\.name))
        return commands.map {
            AgentSkill(name: $0.name, description: $0.commandLine, argumentHint: nil, path: nil, origin: .command)
        } + availableSkills.filter { !names.contains($0.name) }
    }

    /// The composer keeps its own undo, which a sent message clears.
    func undoManager(for view: NSTextView) -> UndoManager? {
        composer.undoManager
    }

    /// While a turn runs, the message is queued, or with `direct` sent as
    /// soon as the turn is stopped. Otherwise it goes after anything queued.
    private func submit(direct: Bool = false, allowsCommands: Bool = false) {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowsCommands, let command = AgentCommand.called(by: text, in: profile.settings.agentCommands) {
            composer.text = ""
            skillCompletion.hide()
            run(command, text: String(text.dropFirst(command.name.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        let images = composer.attachments
        let written = !text.isEmpty || !images.isEmpty
        guard written || (!isBusy && !queued.isEmpty) else { return }
        if !text.isEmpty { profile.agentHistory.addPrompt(text) }
        recalled = nil
        composer.text = ""
        composer.attachments = []
        skillCompletion.hide()
        if isBusy {
            if direct {
                // A second Ctrl+Enter before the turn has stopped joins the first.
                pendingDirect = pendingDirect.map { Self.merged([$0, (text, images)]) } ?? (text, images)
                stopTurn()
            } else {
                queued.append((text, images))
            }
            return
        }
        if written { queued.append((text, images)) }
        queuePaused = false
        sendQueued()
    }

    // MARK: Sent messages

    /// Puts the next older or newer sent message in the field, if the caret
    /// is on the first line for older or the last for newer. Returns whether
    /// it took the key.
    private func stepThroughSent(older: Bool) -> Bool {
        guard older ? composer.caretOnFirstLine : composer.caretOnLastLine else { return false }
        if recalled == nil {
            let prompts = profile.agentHistory.prompts
            guard older, !prompts.isEmpty else { return false }
            draft = composer.text
            recalled = (prompts, prompts.count)
        }
        guard let (prompts, index) = recalled else { return false }
        let next = index + (older ? -1 : 1)
        if next < 0 {
            NSSound.beep()
        } else if next >= prompts.count {
            recall(draft, focus: false)
        } else {
            recall(prompts[next], focus: false)
            recalled = (prompts, next)
        }
        return true
    }

    /// Replaces the field's text with `text`, caret at the end. Images
    /// attached stay.
    private func recall(_ text: String, focus: Bool) {
        recalled = nil
        skillCompletion.hide()
        composer.text = text
        if focus { window?.makeFirstResponder(composer.textView) }
        composer.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        composer.textView.scrollRangeToVisible(composer.textView.selectedRange())
    }

    /// Opens the search of sent messages above the field.
    private func searchPrompts() {
        let prompts = profile.agentHistory.prompts
        guard !prompts.isEmpty else { return NSSound.beep() }
        skillCompletion.hide()
        promptSearch.show(prompts.reversed())
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let images = menu.addItem(withTitle: "Add Images…", action: #selector(chooseImages(_:)), keyEquivalent: "")
        images.target = self
        images.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let search = menu.addItem(withTitle: "Search Sent Messages…", action: #selector(searchSent(_:)), keyEquivalent: "r")
        search.keyEquivalentModifierMask = .control
        search.target = self
        search.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        search.isEnabled = !profile.agentHistory.prompts.isEmpty
        // Above the button, as the model and tools menus open.
        menu.popUp(above: sender)
    }

    @objc private func searchSent(_ sender: Any?) { searchPrompts() }

    // MARK: Model and tools

    /// Puts this chat's model and tools on the message field's buttons.
    func showOptions() {
        let options = modelOptions
        composer.showOptions(
            model: options.shortTitle(for: choice), summary: options.summary(for: choice), isDefault: options.isDefault,
            tools: tools
        )
    }

    @objc private func showModel(_ sender: NSButton) { onModel?(sender) }
    @objc private func showTools(_ sender: NSButton) { onTools?(sender) }

    #if DEBUG
    /// Clicks the model or tools button for `ui.agentAction`, so what opens
    /// hangs off that button, as it does for a real click.
    func modelForTesting() { onModel?(composer.modelButton) }
    func toolsForTesting() { onTools?(composer.toolsButton) }
    #endif

    private func run(_ command: AgentCommand, text: String) {
        loadIfNeeded(now: true)
        hideEmptyState()
        let name = "/" + command.name
        let row = ToolRowView(name: name, detail: text)
        let index = records.count
        records.append(.tool(name: name, detail: text, isError: nil, summary: ""))
        saveRecords()
        transcript.add(row)
        scrollToBottom()
        var payload = commandContext?() ?? [:]
        payload["text"] = text
        payload["source"] = "tiller"
        let input = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let environment = AgentEnvironment.commandEnvironment(socket: profile.socketPath)
        Task { [weak self] in
            let result = await Task.detached {
                AgentCommandRunner.run(command.commandLine, input: input, environment: environment)
            }.value
            guard let self else { return }
            row.finish(isError: result.isError, summary: result.summary)
            records[index] = .tool(name: name, detail: text, isError: result.isError, summary: result.summary)
            saveRecords()
            transcript.needsLayout = true
        }
    }

    // MARK: Queue

    /// Sends Ctrl+Enter's message if there is one, else what is queued,
    /// unless the queue is paused. Called once a turn has ended.
    private func sendQueued() {
        guard !isBusy else { return }
        if let direct = pendingDirect {
            pendingDirect = nil
            send(direct.text, images: direct.images)
            return
        }
        guard !queuePaused, !queued.isEmpty else { return }
        // Up to the next message that calls a skill.
        let count = queued.dropFirst().firstIndex { $0.text.hasPrefix("/") } ?? queued.count
        let batch = Self.merged(Array(queued.prefix(count)))
        queued.removeFirst(count)
        send(batch.text, images: batch.images)
    }

    private static func merged(_ messages: [Message]) -> Message {
        (messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), messages.flatMap(\.images))
    }

    /// A turn that didn't finish pauses the queue. What is next is sent
    /// after the event that ended the turn has been handled, since that may
    /// still be stopping the process.
    private func turnEnded(finished: Bool) {
        if !finished, !queued.isEmpty { queuePaused = true }
        guard pendingDirect != nil || !queued.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.sendQueued() } }
    }

    /// Takes a queued message back into the field, after what is written there.
    private func editQueued(at index: Int) {
        guard queued.indices.contains(index) else { return }
        let message = queued.remove(at: index)
        let written = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        composer.text = written.isEmpty ? message.text : written + "\n\n" + message.text
        composer.attachments += message.images
        window?.makeFirstResponder(composer.textView)
        composer.textView.setSelectedRange(NSRange(location: (composer.text as NSString).length, length: 0))
    }

    private func removeQueued(at index: Int) {
        guard queued.indices.contains(index) else { return }
        for image in queued.remove(at: index).images { try? FileManager.default.removeItem(at: image.url) }
    }

    private func updateQueue() {
        if queued.isEmpty, queuePaused { queuePaused = false }
        queueView.show(queued.map { ($0.text, $0.images.count) }, paused: queuePaused)
        composer.hasQueued = !queued.isEmpty
    }

    /// `contextOverride` replaces the selected tab's description, and
    /// `schedule` marks the message as that schedule's run.
    func send(
        _ text: String, images: [AgentAttachment] = [], contextOverride: String? = nil, schedule: ScheduledPrompt? = nil
    ) {
        loadIfNeeded(now: true)
        var conversation = conversation ?? AgentConversation(
            id: id, kind: kind, provider: choice.provider, title: schedule?.name ?? AgentConversation.title(from: text), created: Date(), updated: Date()
        )
        if let schedule, conversation.scheduleID == nil { conversation.scheduleID = schedule.id }
        conversation.tools = tools
        conversation.modelOptions = modelOptions
        conversation.updated = Date()
        save(conversation)
        let session = self.session ?? makeSession()
        hideEmptyState()
        if let schedule { addNote("Scheduled run of “\(schedule.name)”") }
        records.append(.user(text: text, images: images.map(\.url.lastPathComponent)))
        saveRecords()
        turnText = nil
        // Only the files are kept for Quick Look, not the images' bytes.
        let urls = images.map(\.url)
        transcript.add(UserMessageView(text: text, images: images.map(\.image)) { [weak self] index in
            self?.preview(urls, at: index)
        })
        lastSent = (text, images)
        let skill = text.hasPrefix("/") ? SkillCompletion.skill(calledBy: text, in: availableSkills) : nil
        let pageContext = contextOverride ?? context?() ?? ""
        guard !session.isRunning, AgentEnvironment.needsShellLookup(session.kind, settings: profile.settings) else {
            return start(session, text: text, images: images, context: pageContext, skill: skill)
        }
        // Finding the CLI takes a login shell, which runs in the background,
        // so the window stays responsive meanwhile. The chat shows it is
        // working, which also holds further messages in the queue.
        lookingUpAgent = true
        agentLookup += 1
        let lookup = agentLookup
        setBusy(true)
        transcript.showThinking()
        scrollToBottom()
        let kind = session.kind
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) { AgentEnvironment.detectedExecutable(for: kind) }.value
            // Unless the chat was stopped or closed meanwhile.
            guard let self, self.lookingUpAgent, self.agentLookup == lookup, self.session === session else { return }
            self.lookingUpAgent = false
            self.start(session, text: text, images: images, context: pageContext, skill: skill)
        }
    }

    /// Hands the message to the agent, starting its CLI if need be.
    private func start(_ session: AgentSession, text: String, images: [AgentAttachment], context: String, skill: AgentSkill?) {
        do {
            // Only a message starting with / can call a skill, so the skill
            // folders are read only then.
            try session.send(text, images: images, context: context, skill: skill)
            if session.isRunning { setStatus("Working…", busy: true) }
            setBusy(true)
            transcript.showThinking()
        } catch let error as AgentSetupError {
            // A CLI that can't be found or run is fixed in Settings.
            addError(error.message, action: openSettings)
            endSession()
            showIdle()
            finishRun(.failed(error.message))
            turnEnded(finished: false)
        } catch {
            let message = (error as? ControlError)?.message ?? error.localizedDescription
            addError(message, action: tryAgain)
            endSession()
            showIdle()
            finishRun(.failed(message))
            turnEnded(finished: false)
        }
        scrollToBottom()
    }

    private func save(_ conversation: AgentConversation) {
        let changed = self.conversation != conversation
        self.conversation = conversation
        profile.agentHistory.save(conversation)
        if changed { onChange?() }
    }

    private func saveRecords() {
        // An unloaded chat has nothing new; writing would empty its file.
        guard conversation != nil, recordsLoaded else { return }
        profile.agentHistory.setRecords(records, for: id)
    }

    /// Continues the saved session if there is one, in the folder it ran in.
    private func makeSession() -> AgentSession {
        let conversation = conversation!
        var directory: URL?
        if conversation.sessionID != nil, let path = conversation.directory {
            directory = URL(fileURLWithPath: path)
        }
        let session = AgentSession(
            profile: profile, kind: conversation.kind, provider: conversation.provider, tools: tools, options: modelOptions, chat: id, resuming: conversation.sessionID,
            in: directory
        )
        session.onEvent = { [weak self] event in self?.handle(event) }
        self.session = session
        resuming = conversation.sessionID != nil
        setStatus("Starting…", busy: true)
        return session
    }

    // MARK: Tools

    /// Changes the built-in tools. The CLIs take them when they start, so a
    /// running agent is stopped and the next message resumes its session with
    /// the new ones. Not while a turn is running.
    func setTools(_ tools: [AgentTool]) {
        guard !isBusy, tools != self.tools else { return }
        self.tools = tools
        if var conversation {
            conversation.tools = tools
            save(conversation)
        }
        if session != nil {
            endSession()
            showIdle()
        }
        onChange?()
    }

    /// Changes the model options. Like the tools, the CLIs take them when they
    /// start, so a running agent is stopped and the next message resumes its
    /// session with the new ones. Not while a turn is running.
    func setModelOptions(_ options: AgentModelOptions) {
        guard !isBusy, options != modelOptions else { return }
        if var conversation {
            conversation.modelOptions = options
            save(conversation)
        } else {
            pickedOptions = options
        }
        if session != nil {
            endSession()
            showIdle()
        }
        onChange?()
    }

    // MARK: Images

    /// Adds pasted, dropped or chosen images to the message, up to the limit.
    /// Beeps for any that don't fit or can't be read.
    private func attach(_ images: [NSImage]) {
        let room = max(0, AgentAttachment.maxCount - composer.attachments.count - pendingAttachments)
        let sources = images.prefix(room).compactMap(AttachmentSource.init)
        if sources.count < images.count { NSSound.beep() }
        guard !sources.isEmpty else { return }
        // Scaling and encoding a screenshot takes a moment, so it happens
        // off the main thread and the thumbnails follow.
        pendingAttachments += sources.count
        let folder = folder
        Task { [weak self] in
            let added = await Task.detached(priority: .userInitiated) {
                sources.compactMap { AgentAttachment(source: $0, in: folder) }
            }.value
            guard let self else { return }
            self.pendingAttachments -= sources.count
            if added.count < sources.count { NSSound.beep() }
            self.composer.attachments += added
        }
    }

    /// Images still being encoded, which count against the limit.
    private var pendingAttachments = 0

    @objc private func chooseImages(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to send to the agent."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK { self.attach(panel.urls.compactMap(NSImage.init(contentsOf:))) }
            window.makeFirstResponder(self.input)
        }
    }

    /// Shows the images in Quick Look, starting at `index`. The panel asks the
    /// responder chain for a controller, so the focus moves into this chat
    /// if it is elsewhere.
    private func preview(_ urls: [URL], at index: Int) {
        quickLook.urls = urls
        quickLook.index = index
        if !hasKeyboardFocus { window?.makeFirstResponder(input) }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.updateController()
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // AppKit calls these on the main thread without saying so.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.reloadData()
            panel.currentPreviewItemIndex = quickLook.index
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    // MARK: Agent events

    private func handle(_ event: AgentEvent) {
        let follow = transcript.isNearBottom(of: scrollView)
        switch event {
        case .ready(let model):
            setStatus(model.map { "Working · \($0)" } ?? "Working…", busy: true)
        case .sessionStarted(let sessionID):
            resuming = false
            guard var conversation else { break }
            conversation.sessionID = sessionID
            conversation.directory = session?.directory?.path
            save(conversation)
        case .renamed(let title):
            guard var conversation else { break }
            conversation.title = title
            save(conversation)
        case .skills(let skills):
            loadedSkills = skills
        case .textStarted:
            liveTextBuffer = ""
            let label = AgentMarkdown.label("")
            liveText = label
            transcript.add(label)
        case .textDelta(let delta):
            liveTextBuffer += delta
            scheduleLiveTextRender()
            return
        case .text(let text):
            let view: MarkdownMessageView
            if let liveText {
                view = liveText
                liveText.text = text
                self.liveText = nil
            } else {
                view = AgentMarkdown.label(text)
                transcript.add(view)
            }
            let date = Date()
            turnText = (view, date)
            records.append(.text(text, date: date))
            saveRecords()
            // The agent may go on to a step, which it can take a while to write.
            showWaiting()
        case .toolUse(let id, let name, let input):
            let detail = ToolRowView.detail(input)
            let full = ToolRowView.full(input, detail: detail)
            let row: ToolRowView
            if let (shown, index) = toolRows[id] {
                // Its row showed as the model started writing it.
                row = shown
                row.fill(detail: detail, full: full)
                records[index] = .tool(name: name, detail: detail, isError: nil, summary: "", full: full)
            } else {
                row = ToolRowView(name: name, detail: detail, full: full)
                records.append(.tool(name: name, detail: detail, isError: nil, summary: "", full: full))
                toolRows[id] = (row, records.count - 1)
                transcript.add(row)
            }
            saveRecords()
            if row.tool == "run_task", let goal = input["goal"] as? String {
                jevRows[goal.trimmingCharacters(in: .whitespacesAndNewlines)] = row
            }
        case .toolProgress(let id, let line):
            guard toolRows[id] != nil else { break }
            if pendingProgress.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.progressInterval) { [weak self] in
                    MainActor.assumeIsolated { self?.showPendingProgress() }
                }
            }
            pendingProgress[id] = line
            return
        case .reasoningStarted:
            reasoningStarted = Date()
            reasoningText = ""
            transcript.activity = ("Thinking", nil)
        case .reasoningDelta(let delta):
            reasoningText += delta
            transcript.activity = ("Thinking", Self.latestReasoningLine(reasoningText))
            return
        case .reasoning(let text):
            let started = reasoningStarted ?? transcript.waitStarted
            reasoningStarted = nil
            reasoningText = ""
            transcript.activity = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            let seconds = started.map { Date().timeIntervalSince($0) }
            records.append(.reasoning(trimmed, seconds: seconds))
            saveRecords()
            transcript.add(ToolRowView(reasoning: trimmed, seconds: seconds))
            showWaiting()
        case .activity(let text):
            transcript.activity = text.map { ($0, nil) }
        case .toolResult(let id, let isError, let summary):
            guard let (row, index) = toolRows.removeValue(forKey: id) else { break }
            jevRows = jevRows.filter { $0.value !== row }
            row.finish(isError: isError, summary: summary)
            if case .tool(let name, let detail, _, _, let full) = records[index] {
                records[index] = .tool(name: name, detail: detail, isError: isError, summary: summary, full: full)
                saveRecords()
            }
            pendingProgress[id] = nil
            // The agent is deciding what to do with the result.
            showWaiting()
        case .retrying:
            setStatus("Retrying…", busy: true)
            transcript.activity = ("Retrying", nil)
        case .error(let message):
            addError(message)
        case .notice(let message):
            addNote(message)
        case .turnFinished(let error, let stopped):
            keepLiveText()
            finishTurnText()
            // A call the turn ended without answering won't be answered now.
            finishToolRows()
            transcript.hideThinking()
            transcript.closeToolGroup()
            if let error { addError(error, action: tryAgain) }
            if stopped { addNote("Stopped") }
            showIdle()
            readTitle()
            finishRun(error.map { .failed($0) } ?? (stopped ? .stopped : .finished(lastAgentText)))
            if error == nil { announce(stopped ? "Stopped" : Self.firstLine(of: lastAgentText) ?? "\(profile.providers.displayName(choice)) finished") }
            turnEnded(finished: error == nil && !stopped)
        case .exited(let message):
            keepLiveText()
            finishTurnText()
            finishToolRows()
            transcript.hideThinking()
            transcript.closeToolGroup()
            if resuming {
                // The saved session couldn't be continued, so start over.
                conversation?.sessionID = nil
                if let conversation { save(conversation) }
                addError((message ?? "\(profile.providers.displayName(choice)) couldn't continue this chat.")
                    + "\nThe next message starts a new conversation, without what was said before.", action: tryAgain)
            } else if let message {
                addError(message + "\nThe next message continues the conversation.", action: tryAgain)
            }
            session = nil
            resuming = false
            showIdle()
            finishRun(.failed(message ?? "\(profile.providers.displayName(choice)) stopped."))
            turnEnded(finished: false)
        }
        if follow { scrollToBottom() } else { updateScrollDownButtonAfterLayout() }
    }

    /// New output below the visible part grows the transcript without moving
    /// the clip, so the button is checked again once the rows are laid out.
    private func updateScrollDownButtonAfterLayout() {
        layoutSubtreeIfNeeded()
        updateScrollDownButton()
    }

    // MARK: Scheduled runs

    /// What a scheduled run tells the agent instead of the selected tab.
    private static func scheduledContext(_ name: String) -> String {
        "[Tiller: scheduled run of \"\(name)\", sent by Tiller on a timer rather than typed. "
            + "No tab is yours: open the tabs you need with new_tab background.]"
    }

    /// Sends the schedule's prompt in this new chat. `completion` gets how
    /// its turn ended, once.
    func runScheduled(_ schedule: ScheduledPrompt, completion: @escaping (AgentRunOutcome) -> Void) {
        runCompletion = completion
        send(schedule.prompt, contextOverride: Self.scheduledContext(schedule.name), schedule: schedule)
    }

    private func finishRun(_ outcome: AgentRunOutcome) {
        guard let completion = runCompletion else { return }
        runCompletion = nil
        // After whatever started the run has finished with the chat.
        DispatchQueue.main.async { completion(outcome) }
    }

    /// The agent's last text since the last message sent.
    private var lastAgentText: String? {
        for record in records.reversed() {
            switch record {
            case .user: return nil
            case .text(let text, _): return text
            default: continue
            }
        }
        return nil
    }

    /// Keeps the text a turn was streaming when it ended without the complete block.
    private func keepLiveText() {
        if let liveText, !liveTextBuffer.isEmpty {
            // A render may still be pending, which would leave the last few
            // characters undrawn and uncopied.
            liveText.text = liveTextBuffer
            let date = Date()
            turnText = (liveText, date)
            records.append(.text(liveTextBuffer, date: date))
            saveRecords()
        }
        liveText = nil
        liveTextStale = false
    }

    /// Gives the turn's last text Copy and its time.
    private func finishTurnText() {
        guard let turnText else { return }
        self.turnText = nil
        showResponseActions(turnText.view, date: turnText.date)
    }

    /// Shows the newest response's Copy and time; older ones show them under the mouse.
    private func showResponseActions(_ view: MarkdownMessageView, date: Date?) {
        view.showActions(date: date)
        pinnedResponse?.isPinned = false
        view.isPinned = true
        pinnedResponse = view
    }

    /// A run_task call of this chat's moved on: its row says what Jev is doing.
    @objc private func jevRunChanged(_ notification: Notification) {
        guard let run = notification.object as? JevRun, let row = jevRows[run.goal], run.isRunning else { return }
        row.showProgress(run.activity)
    }

    /// Calls still running when the agent ended get a mark of their own.
    /// What it was busy with ended too.
    private func finishToolRows() {
        for (row, _) in toolRows.values { row.finish(isError: nil, summary: "") }
        toolRows.removeAll()
        jevRows.removeAll()
        pendingProgress.removeAll()
        reasoningStarted = nil
        reasoningText = ""
        transcript.activity = nil
    }

    /// The Thinking row, while the agent works on with no call running.
    private func showWaiting() {
        if toolRows.isEmpty, isBusy { transcript.showThinking() }
    }

    private func showPendingProgress() {
        let follow = transcript.isNearBottom(of: scrollView)
        for (id, line) in pendingProgress {
            toolRows[id]?.row.showProgress(line, isOutput: true)
        }
        pendingProgress.removeAll()
        if follow { scrollToBottom() }
    }

    /// The newest heading of a Codex summary, or the newest line of other
    /// reasoning, for the Thinking row while it streams.
    private static func latestReasoningLine(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let heading = lines.last(where: { $0.hasPrefix("**") && $0.hasSuffix("**") && $0.count > 4 }) {
            return String(heading.dropFirst(2).dropLast(2))
        }
        guard let last = lines.last else { return nil }
        // Streaming, the line's end may be a few words in.
        return last.count > 120 ? "…" + String(last.suffix(120)) : last
    }

    /// Claude Code and Qoder CLI may name the session in their own files.
    private func readTitle() {
        guard let conversation, let sessionID = conversation.sessionID, let directory = conversation.directory else { return }
        let kind = conversation.kind
        Task { [weak self] in
            let title = await Task.detached {
                AgentSessionTitle.read(kind: kind, sessionID: sessionID, directory: directory)
            }.value
            guard let self, let title, var conversation = self.conversation, conversation.title != title else { return }
            conversation.title = title
            self.save(conversation)
        }
    }

    private func scheduleLiveTextRender() {
        guard !liveTextRenderPending else { return }
        liveTextRenderPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveTextInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveTextRenderPending = false
                guard let liveText = self.liveText else { return }
                // Hidden, nothing is drawn, so the text waits until it shows.
                guard !self.isHiddenOrHasHiddenAncestor else {
                    self.liveTextStale = true
                    return
                }
                self.liveTextStale = false
                let follow = self.transcript.isNearBottom(of: self.scrollView)
                liveText.text = self.liveTextBuffer
                if follow { self.scrollToBottom() } else { self.updateScrollDownButtonAfterLayout() }
            }
        }
    }

    private func showIdle() {
        setBusy(false)
        setStatus(session == nil ? "" : "Ready", busy: false)
        composer.placeholder = "Ask \(profile.providers.displayName(choice)) about this page…"
        composer.shortPlaceholder = "Ask \(profile.providers.displayName(choice))…"
        emptyState.show(choice, name: profile.providers.displayName(choice))
        let showEmpty = transcript.isEmpty && recordsLoaded
        if showEmpty { emptyState.alphaValue = 1 }
        emptyState.isHidden = !showEmpty
    }

    /// Fades the suggestions out as the first message goes in, rather than
    /// dropping them in the same frame. `showIdle` brings them back at full
    /// strength, and a fade it overtook leaves them shown.
    private func hideEmptyState() {
        guard !emptyState.isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.standard
            emptyState.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.emptyState.alphaValue == 0 else { return }
                self.emptyState.isHidden = true
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        guard composer.isBusy != busy else { return }
        composer.isBusy = busy
        onChange?()
    }

    private func setStatus(_ text: String, busy: Bool) {
        guard text != statusText || busy != statusBusy else { return }
        statusText = text
        statusBusy = busy
        onChange?()
    }

    private func addNote(_ message: String) {
        records.append(.note(message))
        saveRecords()
        transcript.add(NoteView(text: message))
    }

    /// `action` offers a way out under the message, such as Try Again. It
    /// shows only now; a saved error has none.
    private func addError(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        records.append(.error(message))
        saveRecords()
        transcript.add(ErrorMessageView(text: message, action: action))
        announce(message)
    }

    /// Tells VoiceOver how a turn went, since the reply lands somewhere in
    /// the transcript with no focus change. Only for the chat in front: a
    /// scheduled run in another tab or window stays quiet.
    private func announce(_ text: String) {
        guard window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private static func firstLine(of text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init)
    }

    /// The last message sent, for trying again after a failure.
    private var lastSent: (text: String, images: [AgentAttachment])?

    /// Sends the last message again, unless a turn is running.
    private var tryAgain: (title: String, run: () -> Void)? {
        guard let lastSent else { return nil }
        return ("Try Again", { [weak self] in
            guard let self, !self.isBusy else { return }
            self.send(lastSent.text, images: lastSent.images)
        })
    }

    /// Opens the Agent pane, where a missing CLI's path is set.
    private var openSettings: (title: String, run: () -> Void) {
        let profile = profile
        return ("Open Settings…", { (NSApp.delegate as? AppDelegate)?.showAgentSettings(profile: profile) })
    }

    /// Draws a saved row, and returns it.
    @discardableResult
    private func show(_ record: AgentRecord, thumbnails: Thumbnails) -> NSView {
        let row: NSView
        switch record {
        case .user(let text, let names):
            let loaded = names.compactMap { name in thumbnails.images[name].map { (folder.appendingPathComponent(name), $0) } }
            let urls = loaded.map(\.0)
            row = UserMessageView(text: text, images: loaded.map(\.1)) { [weak self] index in
                self?.preview(urls, at: index)
            }
        case .text(let text, _):
            row = AgentMarkdown.label(text)
        case .tool(let name, let detail, let isError, let summary, let full):
            row = ToolRowView(name: name, detail: detail, full: full, finished: (isError, summary))
        case .reasoning(let text, let seconds):
            row = ToolRowView(reasoning: text, seconds: seconds)
        case .note(let text):
            row = NoteView(text: text)
        case .error(let text):
            row = ErrorMessageView(text: text)
        }
        transcript.add(row)
        return row
    }

    /// Keeps the newest message in view. Agent events call this only when the
    /// user hasn't scrolled up to read something.
    func scrollToBottom() {
        // Hidden, a layout here is wasted; `layout` scrolls once it shows.
        guard !isHiddenOrHasHiddenAncestor else {
            pendingScrollToBottom = true
            return
        }
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: bottomOffset))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The clip's origin with the last message just above the bottom inset.
    /// The clip spans the insets too, so the top rests at minus the top inset.
    private var bottomOffset: CGFloat {
        let clipHeight = scrollView.contentView.bounds.height
        return max(-Self.insets.top, transcript.frame.height - clipHeight + Self.insets.bottom)
    }
}

/// The transcript's mask: opaque, except for a short ramp to clear at the
/// top and bottom edges. The ramps fall within the scroll view's insets and
/// the transcript's own padding, so text at rest is never faded, only text
/// scrolled past an edge.
final class EdgeFadeMask: CAGradientLayer {
    static let height: CGFloat = 16

    override init() {
        super.init()
        colors = [CGColor.clear, CGColor.black, CGColor.black, CGColor.clear]
        // Layer y runs up, so the first stop is the bottom edge.
        startPoint = CGPoint(x: 0.5, y: 0)
        endPoint = CGPoint(x: 0.5, y: 1)
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError() }

    /// Spans `bounds`, the scroll view's, with ramps of `height` points.
    func fit(_ bounds: NSRect) {
        guard bounds.height > 0, frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = bounds
        let ramp = min(0.5, Self.height / bounds.height) as NSNumber
        locations = [0, ramp, NSNumber(value: 1 - ramp.doubleValue), 1]
        CATransaction.commit()
    }
}

/// A round button with a down arrow that floats over the transcript while
/// the newest message is out of view. It fades in and out, and its plate
/// darkens under the mouse and while pressed.
final class ScrollDownButton: NSButton {
    private var shown = false
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        image = Theme.symbol("arrow.down", size: Theme.Symbol.row, weight: .semibold, label: "Scroll to Newest")
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .accessoryBarAction
        contentTintColor = Theme.text
        toolTip = "Scroll to Newest"
        setAccessibilityLabel("Scroll to Newest")
        alphaValue = 0
        isHidden = true
        // A little larger than a bar button, since it floats over text.
        let side = Theme.ButtonSize.bar + 4
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        if show { isHidden = false }
        let reduceMotion = Theme.reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Theme.Duration.standard
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.isHidden = true
            }
        }
    }

    /// Only this area is replaced, so the ones AppKit keeps for the tooltip stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // A hidden view gets no exit event, so the hover is dropped on hiding.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2
        // The plate stays opaque over the text, so the hover and pressed
        // fills are mixed into it rather than laid on top. Mixed here, where
        // the view's appearance is current.
        let fill = isHighlighted ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : 0
        let plate = Theme.chrome.blended(withFraction: fill, of: Theme.text) ?? Theme.chrome
        withEasing(Theme.Duration.quick) { layer.backgroundColor = plate.layerColor }
        layer.borderWidth = Theme.hairlineWidth
        layer.borderColor = Theme.hairline.layerColor
        layer.shadowColor = NSColor.black.layerColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }
}
