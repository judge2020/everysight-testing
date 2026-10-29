import UIKit
import MaverickAI

final class ViewController: UITableViewController {
    private let discord = DiscordBridge()
    private let connectionListener = ConnectionListener()
    private let statusLabel = UILabel()
    private let glassesLabel = UILabel()
    private let noticeLabel = UILabel()
    private let signInButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let configureButton = UIButton(type: .system)
    private let mirrorSwitch = UISwitch()
    private let preferences = UserDefaults.standard
    private var pump: Timer?
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var foreground = true
    private var initialized = false
    private var nextRetry: TimeInterval = 0
    private var retryDelay: TimeInterval = 1
    private var connectionStarted: TimeInterval?
    private var hud: MessageHUD?
    private var conversations: [[AnyHashable: Any]] = []
    private var messages: [DiscordMessage] = []
    private enum HUDFocus { case conversations, messages }
    private var hudFocus = HUDFocus.conversations
    private var highlightedUser: String?
    private var previewMessages: [String: [DiscordMessage]] = [:]
    private var highlightedConversationIndex: Int {
        conversations.firstIndex { $0["userID"] as? String == (highlightedUser ?? selectedUser) } ?? 0
    }
    private var selectedUser: String?
    private var selectedMessageID: String?
    private var page = 0
    private var displayRevision = 0
    private var visibleUntil: Date?
    private var loadingConversations = false
    private var historyRequest = UUID()
    private var loadingHistory = false
    private var historyChanges: [String: DiscordMessage] = [:]
    private var historyDeletions = Set<String>()
    private var captureCover: UIView?
    private var autoReconnect: Bool {
        get { preferences.object(forKey: "autoReconnect") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "autoReconnect") }
    }
    private var mirrorsMessages: Bool {
        get { preferences.object(forKey: "mirrorDiscordMessages") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "mirrorDiscordMessages") }
    }
    private var hasKey: Bool {
        guard let url = Bundle.main.url(forResource: "sdk", withExtension: "key"),
              let data = try? Data(contentsOf: url) else { return false }
        return !data.isEmpty
    }
    private var ready: Bool { initialized && Evs.shared.glassesService.isReady() }
    private var previewing: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--discord-hud-preview")
#else
        false
#endif
    }
    private var selectedMessage: DiscordMessage? { messages.first { $0.id == selectedMessageID } }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Discord Glasses"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Sign out", style: .plain, target: self, action: #selector(signOut))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reloadDiscord), for: .valueChanged)
        buildHeader()
        discord.statusChanged = { [weak self] status, isReady in
            guard let self else { return }
            self.statusLabel.text = "Discord · \(status)"
            self.statusLabel.textColor = isReady ? .systemIndigo : .secondaryLabel
            self.signInButton.isEnabled = self.discord.configured && !isReady
            if isReady { self.loadConversations() }
            else { self.hideMessage() }
            self.sizeHeader()
        }
        discord.messageChanged = { [weak self] value, incoming in
            guard let self, let message = DiscordMessage(value) else { return }
            self.receive(message, incoming: incoming)
        }
        discord.messageDeleted = { [weak self] id in
            guard let self else { return }
            if self.loadingHistory { self.historyDeletions.insert(id) }
            self.historyChanges.removeValue(forKey: id)
            self.messages.removeAll { $0.id == id }
            if self.selectedMessageID == id { self.hideMessage(); self.selectedMessageID = nil }
            self.tableView.reloadData()
        }
        discord.sessionCleared = { [weak self] in
            guard let self else { return }
            self.historyRequest = UUID(); self.loadingConversations = false; self.loadingHistory = false
            self.historyChanges.removeAll(); self.historyDeletions.removeAll()
            self.conversations.removeAll(); self.messages.removeAll()
            self.selectedUser = nil; self.selectedMessageID = nil; self.highlightedUser = nil; self.hudFocus = .conversations
            self.noticeLabel.text = "Signed out. Message previews cleared."
            self.hideMessage(); self.tableView.reloadData()
        }
        connectionListener.changed = { [weak self] in DispatchQueue.main.async { self?.connectionChanged() } }
        connectionListener.failed = { [weak self] in DispatchQueue.main.async {
            guard let self, self.autoReconnect, self.connectionStarted != nil else { return }
            self.connectionStarted = nil
            self.nextRetry = ProcessInfo.processInfo.systemUptime + self.retryDelay
            self.retryDelay = min(self.retryDelay * 2, 15)
        } }
        connectionListener.configured = { [weak self] in DispatchQueue.main.async {
            self?.nextRetry = 0; self?.retryDelay = 1
        } }
        observeLifecycle()
        Evs.shared.doInit()
        initialized = true
        Evs.shared.glassesService.registerConnectionListener(listener: connectionListener)
        restoreSuccessfulTargetIfNeeded()
        // SDK callbacks are pumped on the main thread, separately from connection checks.
        let pump = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.discord.pump() }
        RunLoop.main.add(pump, forMode: .common); self.pump = pump
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshGlasses() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refreshGlasses()
        if previewing {
            statusLabel.text = "TEST PREVIEW · Discord is not connected"
            let sampleText = "This is a local test message for the split glasses display. Choose a conversation on the left, then read messages on the right. Tap to advance through long messages. Swipe up or down to browse messages; swipe back to return to the DM selector. Hold to hide message text. This sample stays entirely on this device."
            for (index, name) in ["Alex", "Morgan", "River", "Casey", "Jordan", "Sam", "Taylor"].enumerated() {
                let userID = "preview-\(index)"
                let samples = (0..<3).map { offset in DiscordMessage([
                    "id": "preview-\(index)-\(offset)", "userID": userID,
                    "author": "\(name) (test)", "conversation": name,
                    "content": offset == 0 ? sampleText : "Older test message \(offset) from \(name).",
                    "timestamp": NSNumber(value: (Date().timeIntervalSince1970 - Double(offset * 60)) * 1000)
                ])! }
                previewMessages[userID] = samples
                conversations.append(["userID": userID, "name": name, "lastMessageID": samples[0].id])
            }
            if let first = conversations.first?["userID"] as? String { loadHistory(first) }
        } else { discord.restoreSession() }
    }

    deinit {
        pump?.invalidate(); timer?.invalidate()
        notifications.forEach(NotificationCenter.default.removeObserver)
        if initialized { Evs.shared.glassesService.unregisterConnectionListener(listener: connectionListener) }
    }

    private func observeLifecycle() {
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.foreground = false; self.hideMessage()
            // Cover message text in the app switcher's snapshot.
            let cover = UIView(frame: self.navigationController?.view.bounds ?? self.view.bounds)
            cover.backgroundColor = .systemBackground
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            (self.navigationController?.view ?? self.view).addSubview(cover)
            self.captureCover = cover
        })
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.foreground = true; self.captureCover?.removeFromSuperview(); self.captureCover = nil
            self.nextRetry = 0; self.refreshGlasses()
            if self.discord.ready { self.loadConversations() }
        })
    }

    @objc private func signIn() { discord.signIn() }
    @objc private func signOut() { discord.signOut(); refreshControl?.endRefreshing() }
    @objc private func reloadDiscord() { loadConversations() }
    private func loadConversations() {
        guard discord.ready, !loadingConversations else { refreshControl?.endRefreshing(); return }
        loadingConversations = true
        discord.loadConversations { [weak self] rows, error in
            guard let self else { return }
            self.loadingConversations = false; self.refreshControl?.endRefreshing()
            if let error { self.noticeLabel.text = "Could not load conversations: \(error)" }
            else {
                self.conversations = rows.sorted {
                    UInt64($0["lastMessageID"] as? String ?? "") ?? 0 > UInt64($1["lastMessageID"] as? String ?? "") ?? 0
                }
                self.noticeLabel.text = rows.isEmpty ? "No conversations available to this app yet. Both people must have used this Discord application for history to appear." : "Choose a conversation, then tap a message to show it on glasses."
            }
            self.tableView.reloadData(); self.sizeHeader()
            if error == nil {
                let userID = self.selectedUser.flatMap { selected in
                    self.conversations.contains { $0["userID"] as? String == selected } ? selected : nil
                } ?? self.conversations.first?["userID"] as? String
                if let userID { self.loadHistory(userID) }
            }
        }
    }
    private func loadHistory(_ userID: String) {
        selectedUser = userID; highlightedUser = userID; selectedMessageID = nil; messages.removeAll(); hideMessage()
        if previewing {
            messages = previewMessages[userID] ?? []
            if let latest = messages.first { show(latest) }
            tableView.reloadData(); updateHUD()
            return
        }
        let displayRevision = self.displayRevision
        historyChanges.removeAll(); historyDeletions.removeAll()
        let request = UUID(); historyRequest = request; loadingHistory = true
        noticeLabel.text = "Loading recent messages…"; tableView.reloadData(); sizeHeader()
        discord.loadMessages(forUser: userID) { [weak self] rows, error in
            guard let self, self.historyRequest == request, self.selectedUser == userID else { return }
            self.loadingHistory = false
            if let error { self.noticeLabel.text = error + " · History requires both people to have used this app." }
            else { self.noticeLabel.text = rows.isEmpty ? "No recent messages in this conversation." : "Tap a message to read it on glasses." }
            var merged = Dictionary(rows.compactMap(DiscordMessage.init).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            self.historyChanges.forEach { merged[$0.key] = $0.value }
            self.historyDeletions.forEach { merged.removeValue(forKey: $0) }
            self.messages = merged.values.sorted { $0.timestamp > $1.timestamp }
            self.historyChanges.removeAll(); self.historyDeletions.removeAll()
            if error == nil, self.foreground, self.discord.ready, self.mirrorsMessages,
               self.displayRevision == displayRevision,
               let latest = self.messages.first(where: { !$0.disclosure }) {
                self.show(latest)
            }
            self.tableView.reloadData(); self.sizeHeader()
        }
    }
    private func receive(_ message: DiscordMessage, incoming: Bool) {
        if let index = conversations.firstIndex(where: { $0["userID"] as? String == message.userID }) {
            conversations[index]["lastMessageID"] = message.id
        } else {
            conversations.insert(["userID": message.userID, "name": message.conversation, "lastMessageID": message.id], at: 0)
        }
        if incoming && mirrorsMessages && foreground && selectedUser != message.userID {
            historyRequest = UUID(); loadingHistory = false; historyChanges.removeAll(); historyDeletions.removeAll()
            selectedUser = message.userID; highlightedUser = message.userID; messages.removeAll()
        }
        if selectedUser == message.userID {
            if loadingHistory { historyChanges[message.id] = message }
            messages.removeAll { $0.id == message.id }; messages.append(message)
            messages.sort { $0.timestamp > $1.timestamp }
            if messages.count > 200 { messages.removeLast(messages.count - 200) }
            if incoming && mirrorsMessages && foreground { show(message) }
            else if selectedMessageID == message.id { page = 0; updateHUD() }
        }
        if incoming { noticeLabel.text = "New direct message received. Tap a message to show it on glasses." }
        tableView.reloadData(); sizeHeader()
    }
    private func show(_ message: DiscordMessage) {
        displayRevision += 1
        selectedMessageID = message.id; page = 0
        visibleUntil = Date().addingTimeInterval(30)
        updateHUD()
    }
    @objc private func hideMessage() { displayRevision += 1; visibleUntil = nil; page = 0; updateHUD() }
    @objc private func nextPage() { turnPage(1) }
    @objc private func previousPage() { turnPage(-1) }
    private func turnPage(_ delta: Int) {
        guard let message = selectedMessage else { return }
        let count = MessageLayout.pages(message.content, columns: 28).count
        page = max(0, min(count - 1, page + delta))
        visibleUntil = Date().addingTimeInterval(30); updateHUD()
    }
    @objc private func openDiscord() { if let message = selectedMessage { discord.openMessage(message.id) } }
    @objc private func mirrorChanged() {
        mirrorsMessages = mirrorSwitch.isOn
        if !mirrorsMessages { hideMessage() }
    }
    private func connectionChanged() {
        if ready { saveSuccessfulTarget(); retryDelay = 1; nextRetry = 0; connectionStarted = nil }
        else { hud = nil; discord.setShowingChat(false) }
        refreshGlasses()
    }
    private func refreshGlasses() {
        guard initialized, foreground else { return }
        if !ready { reconnectIfNeeded() }
        let service = Evs.shared.glassesService
        glassesLabel.text = "Glasses · \(ready ? "Ready" : service.getConnectionStatus().name)\n\(hasKey ? "" : "Developer key missing · ")\(service.getDeviceName())"
        connectButton.setTitle(service.isConnected() || connectionStarted != nil ? "Disconnect" : "Connect", for: .normal)
        connectButton.isEnabled = hasKey && service.hasConfiguredDevice()
        if let until = visibleUntil, until <= Date() { visibleUntil = nil; displayRevision += 1 }
        updateHUD(); sizeHeader()
    }
    @objc private func configure() {
        nextRetry = .greatestFiniteMagnitude; connectionStarted = nil
        Evs.shared.glassesService.disconnect(); autoReconnect = true
        Evs.shared.showAppUI(option: M2AppUIOption.companion.DefaultConfigure)
    }
    @objc private func toggleConnection() {
        let service = Evs.shared.glassesService
        if service.isConnected() || connectionStarted != nil {
            autoReconnect = false; connectionStarted = nil; service.disconnect()
        } else { autoReconnect = true; nextRetry = 0; retryDelay = 1; reconnectIfNeeded() }
        refreshGlasses()
    }
    private func handleHUDTouch(_ touch: M2Touch) {
        guard foreground else { return }
        if touch == .longtap {
            hudFocus = .conversations; hideMessage()
        } else if touch == .backward {
            hudFocus = .conversations; updateHUD()
        } else if touch == .up || touch == .down {
            let delta = touch == .up ? -1 : 1
            if hudFocus == .conversations {
                guard !conversations.isEmpty else { return }
                let index = (highlightedConversationIndex + delta + conversations.count) % conversations.count
                highlightedUser = conversations[index]["userID"] as? String
                updateHUD()
            } else {
                guard !messages.isEmpty else { return }
                let index = messages.firstIndex { $0.id == selectedMessageID } ?? 0
                let next = max(0, min(messages.count - 1, index + delta))
                show(messages[next]); tableView.reloadData()
            }
        } else if touch == .tap || touch == .forward {
            if hudFocus == .conversations {
                guard conversations.indices.contains(highlightedConversationIndex),
                      let userID = conversations[highlightedConversationIndex]["userID"] as? String else { return }
                hudFocus = .messages
                if selectedUser == userID, let latest = messages.first { show(latest) }
                else { loadHistory(userID) }
                updateHUD()
            } else if let message = selectedMessage {
                let count = MessageLayout.pages(message.content, columns: 28).count
                page = (page + 1) % count
                visibleUntil = Date().addingTimeInterval(30); displayRevision += 1
                updateHUD()
            }
        }
    }
    private func updateHUD() {
        guard initialized else { return }
        guard ready else { discord.setShowingChat(false); return }
        if hud == nil {
            let screen = MessageHUD()
            screen.gesture = { [weak self] touch in DispatchQueue.main.async { self?.handleHUDTouch(touch) } }
            hud = screen; Evs.shared.screenService.addScreen(screen: screen)
        }
        let showing = foreground && visibleUntil != nil && selectedMessage != nil && (discord.ready || previewing)
        discord.setShowingChat(showing)
        let names = foreground ? conversations.map { $0["name"] as? String ?? "Discord user" } : []
        let conversation = selectedMessage?.conversation
            ?? conversations.first(where: { $0["userID"] as? String == selectedUser })?["name"] as? String
            ?? "Messages"
        var sender = ""
        var body = [foreground && (discord.ready || previewing) ? "Choose a DM on the left" : "Messages hidden"]
        var position = ""
        if loadingHistory { body = ["Loading messages…"] }
        if showing, let message = selectedMessage {
            let pages = MessageLayout.pages(message.content, columns: 28)
            page = min(page, pages.count - 1)
            let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: message.timestamp / 1000), dateStyle: .none, timeStyle: .short)
            sender = "\(message.author) · \(time)\(message.edited ? " *" : "")"
            body = pages[page]
            let index = messages.firstIndex { $0.id == message.id } ?? 0
            position = "Msg \(index + 1)/\(messages.count) p\(page + 1)/\(pages.count) · "
        }
        let hint = hudFocus == .conversations ? "Up/down: DM · Tap/right: open" : "Up/down: msg · Tap: page · Left: DMs"
        hud?.update(names: names, highlighted: highlightedConversationIndex,
                    focusDMs: hudFocus == .conversations, conversation: foreground ? conversation : "DISCORD",
                    sender: sender, body: body,
                    footer: foreground ? position + hint + " · Hold: hide" : "",
                    testing: previewing)
    }

    private func buildHeader() {
        let title = UILabel(); title.text = "Your messages, at a glance."
        title.font = .preferredFont(forTextStyle: .title2); title.numberOfLines = 0
        [statusLabel, glassesLabel, noticeLabel].forEach { $0.numberOfLines = 0; $0.font = .preferredFont(forTextStyle: .subheadline) }
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.text = "Sign in, then connect your glasses. New incoming DMs appear for 30 seconds while this app is active."
        func button(_ title: String, _ action: Selector, _ button: UIButton = UIButton(type: .system)) -> UIButton {
            button.setTitle(title, for: .normal); button.addTarget(self, action: action, for: .touchUpInside)
            return button
        }
        button("Sign in with Discord", #selector(signIn), signInButton).configuration = .filled()
        _ = button("Configure glasses", #selector(configure), configureButton)
        _ = button("Connect", #selector(toggleConnection), connectButton)
        let connection = UIStackView(arrangedSubviews: [configureButton, connectButton]); connection.distribution = .fillEqually
        let mirrorLabel = UILabel(); mirrorLabel.text = "Show incoming DMs on glasses"; mirrorLabel.numberOfLines = 0
        mirrorSwitch.isOn = mirrorsMessages; mirrorSwitch.addTarget(self, action: #selector(mirrorChanged), for: .valueChanged)
        let mirror = UIStackView(arrangedSubviews: [mirrorLabel, mirrorSwitch]); mirror.spacing = 12
        let controls = UIStackView(arrangedSubviews: [button("Previous", #selector(previousPage)), button("Next", #selector(nextPage)), button("Hide", #selector(hideMessage))]); controls.distribution = .fillEqually
        let limits = UILabel(); limits.numberOfLines = 0; limits.font = .preferredFont(forTextStyle: .footnote); limits.textColor = .secondaryLabel
        limits.text = "Social SDK messages only. History requires both people to have used this app; up to 72 hours. This is not your full Discord inbox. Images and other attachments open in Discord. Message previews clear when the app is inactive."
        let stack = UIStackView(arrangedSubviews: [title, statusLabel, signInButton, glassesLabel, connection, mirror, controls, button("Open selected message in Discord", #selector(openDiscord)), noticeLabel, limits])
        stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView(); header.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20), stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12)])
        tableView.tableHeaderView = header
    }
    private func sizeHeader() {
        guard let header = tableView.tableHeaderView else { return }
        let height = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        if abs(header.frame.height - height) > 1 {
            header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height); tableView.tableHeaderView = header
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); sizeHeader() }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Conversations" : "Recent messages" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? max(1, conversations.count) : max(1, messages.count) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "message")
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.numberOfLines = 4
        cell.accessoryType = .none
        if indexPath.section == 0 {
            if conversations.isEmpty { content.text = "No conversations yet"; content.secondaryText = "Pull down to refresh after signing in." }
            else {
                let row = conversations[indexPath.row]
                content.text = row["name"] as? String
                content.secondaryText = "Load recent messages"
                if row["userID"] as? String == selectedUser { cell.accessoryType = .checkmark }
            }
        } else if messages.isEmpty { content.text = "No messages loaded"; content.secondaryText = "Choose a conversation above, or wait for an incoming DM." }
        else {
            let message = messages[indexPath.row]
            let date = Date(timeIntervalSince1970: message.timestamp / 1000)
            content.text = "\(message.author) · \(DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short))\(message.edited ? " · edited" : "")"
            content.secondaryText = message.content
            if message.id == selectedMessageID { cell.accessoryType = .checkmark }
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0, conversations.indices.contains(indexPath.row), let userID = conversations[indexPath.row]["userID"] as? String { hudFocus = .messages; loadHistory(userID) }
        else if indexPath.section == 1, messages.indices.contains(indexPath.row) { hudFocus = .messages; show(messages[indexPath.row]); tableView.reloadData() }
    }
    private func restoreSuccessfulTargetIfNeeded() {
        let service = Evs.shared.glassesService
        guard autoReconnect, !service.hasConfiguredDevice() else { return }
        if let host = preferences.string(forKey: "lastSimulatorHost"), !host.isEmpty {
            service.setConfiguredSimulator(simulatorIpOrHost: host, autoConnect: false)
        } else if let address = preferences.string(forKey: "lastGlassesAddress"), !address.isEmpty {
            service.setConfiguredDevice(address: address, name: preferences.string(forKey: "lastGlassesName"), autoConnect: false)
        }
    }

    private func saveSuccessfulTarget() {
        let service = Evs.shared.glassesService
        if service.isSimulatorConfigured() {
            preferences.set(service.getConfiguredSimulatorHost(), forKey: "lastSimulatorHost")
            preferences.removeObject(forKey: "lastGlassesAddress")
            preferences.removeObject(forKey: "lastGlassesName")
        } else {
            preferences.set(service.getDeviceAddress(), forKey: "lastGlassesAddress")
            preferences.set(service.getDeviceName(), forKey: "lastGlassesName")
            preferences.removeObject(forKey: "lastSimulatorHost")
        }
    }

    private func reconnectIfNeeded() {
        let service = Evs.shared.glassesService
        guard foreground, autoReconnect, hasKey, service.hasConfiguredDevice(), !ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let started = connectionStarted {
            if now - started < 20 { return }
            service.disconnect()
            connectionStarted = nil
            nextRetry = now + retryDelay
            retryDelay = min(retryDelay * 2, 15)
            return
        }
        guard now >= nextRetry else { return }
        if service.isConnected() || service.getConnectionStatus() == .connecting {
            connectionStarted = now
            return
        }
        connectionStarted = now
        nextRetry = now + retryDelay
        service.connect()
    }

    private final class ConnectionListener: NSObject, IM2GlassesConnectionEvents {
        var changed: (() -> Void)?
        var failed: (() -> Void)?
        var configured: (() -> Void)?
        func onConfigureDevice(address: String?, name: String?) { configured?(); changed?() }
        func onConnectionStatusChanged(status: M2ConnectionStatus) {
            if status == .failed || status == .authfailed || status == .disconnected { failed?() }
            changed?()
        }
        func onReady() { changed?() }
        func onUnReady() { changed?() }
    }
    private final class MessageHUD: M2Screen {
        var gesture: ((M2Touch) -> Void)?
        private var dmHeader: M2Text?
        private var dmRows: [M2Text] = []
        private var conversationText: M2Text?
        private var senderText: M2Text?
        private var bodyRows: [M2Text] = []
        private var footerText: M2Text?
        private var names: [String] = []
        private var highlighted = 0
        private var focusDMs = true
        private var conversation = "Messages"
        private var sender = ""
        private var body: [String] = []
        private var footer = ""
        private var testing = false

        init() { super.init(width: 540, height: 320, tag: "discord-messages") }
        override func onCreate() {
            dmRows.removeAll(); bodyRows.removeAll()
            func label(_ tag: String, x: Float, y: Float, scale: Float) -> M2Text {
                let text = M2Text(text: "", tag: tag)
                _ = text.setXY(x: x, y: y); _ = text.setScale(scale: scale)
                _ = text.setColor(evsColor: .white); _ = add(drawable: text)
                return text
            }
            dmHeader = label("dm-header", x: 14, y: 22, scale: 0.6)
            for index in 0..<6 { dmRows.append(label("dm-\(index)", x: 14, y: Float(66 + index * 33), scale: 0.55)) }
            let divider = M2RectOutline(color: .green, tag: "dm-divider")
            _ = divider.setDimensions(x: 162, y: 16, width: 1, height: 252)
            _ = add(drawable: divider)
            conversationText = label("conversation", x: 178, y: 22, scale: 0.65)
            senderText = label("sender", x: 178, y: 56, scale: 0.48)
            for index in 0..<5 { bodyRows.append(label("body-\(index)", x: 178, y: Float(94 + index * 34), scale: 0.65)) }
            footerText = label("navigation", x: 14, y: 285, scale: 0.4)
            render()
        }
        override func onRelease() {
            dmHeader = nil; dmRows.removeAll(); conversationText = nil; senderText = nil
            bodyRows.removeAll(); footerText = nil
            super.onRelease()
        }
        override func onTouch(touch: M2Touch) { gesture?(touch) }
        func update(names: [String], highlighted: Int, focusDMs: Bool, conversation: String,
                    sender: String, body: [String], footer: String, testing: Bool) {
            self.names = names; self.highlighted = highlighted; self.focusDMs = focusDMs
            self.conversation = conversation; self.sender = sender; self.body = body
            self.footer = footer; self.testing = testing
            render()
        }
        private func render() {
            let start = max(0, min(highlighted - 2, names.count - 6))
            let count = names.isEmpty ? "" : " \(highlighted + 1)/\(names.count)"
            _ = dmHeader?.setText(text: (testing ? "TEST DMs" : "DMs") + count)
            _ = dmHeader?.setColor(evsColor: focusDMs ? .green : .white)
            for (offset, text) in dmRows.enumerated() {
                let index = start + offset
                let selected = index == highlighted
                let value = names.indices.contains(index) ? (selected ? "> " : "  ") + String(names[index].prefix(13)) : ""
                _ = text.setText(text: value)
                _ = text.setColor(evsColor: selected ? .green : .white)
            }
            _ = conversationText?.setText(text: String(((focusDMs ? "" : "> ") + conversation).prefix(28)))
            _ = conversationText?.setColor(evsColor: focusDMs ? .white : .green)
            _ = senderText?.setText(text: String(sender.prefix(38)))
            for (index, text) in bodyRows.enumerated() { _ = text.setText(text: body.indices.contains(index) ? body[index] : "") }
            _ = footerText?.setText(text: footer)
        }
    }
}
