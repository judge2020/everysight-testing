import UIKit
import MaverickAI

final class ViewController: UITableViewController {
    private struct Row {
        let key: String
        let title: String
    }
    private struct Section {
        let title: String
        let note: String
        let rows: [Row]
    }
    private let monitor = SensorMonitor()
    private let connectionListener = ConnectionListener()
    private let statusLabel = UILabel()
    private let cadenceLabel = UILabel()
    private let configureButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let reconnectSwitch = UISwitch()
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var latest: SensorSnapshot?
    private var ticks = 0
    private var monitoringWanted = true
    private var foreground = true
    private var initialized = false
    private var nextRetry: TimeInterval = 0
    private var retryDelay: TimeInterval = 1
    private var connectionStarted: TimeInterval?
    private var hud: StatusHUD?
    private let preferences = UserDefaults.standard
    private var autoReconnect: Bool {
        get { preferences.object(forKey: "autoReconnect") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "autoReconnect") }
    }
    private var hasKey: Bool {
        guard let url = Bundle.main.url(forResource: "sdk", withExtension: "key"),
              let bytes = try? Data(contentsOf: url) else { return false }
        return !bytes.isEmpty
    }
    private var isSimulator: Bool { initialized && Evs.shared.glassesService.isSimulatorConfigured() }
    private var ready: Bool { initialized && Evs.shared.glassesService.isReady() }

    private var sections: [Section] {
        let simulated = isSimulator
        return [
            Section(title: "Device & environment", note: "Values refresh every second. Event readings include their age; missing data is never shown as zero.", rows: [
                Row(key: "battery", title: "Battery"), Row(key: "batteryPower", title: "Battery power"),
                Row(key: "charging", title: "Charging"), Row(key: "ambient", title: "Ambient light"),
                Row(key: "proximity", title: "Proximity · on-face detection"),
                Row(key: "brightness", title: "Display brightness"), Row(key: "display", title: "Display power"),
                Row(key: "autoBrightness", title: "Auto brightness")]),
            Section(title: "Eye tracking", note: simulated
                ? "Simulator eye features are synthetic, not measurements of your eye. Values below come from SDK callbacks. Eye-camera coordinates are not calibrated screen gaze."
                : "Eye-camera coordinates. Iris/pupil: center x, center y, axes a, b, angle. Pupil position is not calibrated screen gaze in SDK 0.2.0.", rows: [
                Row(key: "eyeState", title: "Tracker state"), Row(key: "eyeFPS", title: "Feature rate"),
                Row(key: "eyeValid", title: "Geometry validity"), Row(key: "pupilVisibility", title: "Pupil visibility"),
                Row(key: "pupilCenter", title: "Filtered pupil center"), Row(key: "iris", title: "Iris ellipse"),
                Row(key: "pupil", title: "Pupil ellipse"), Row(key: "earCorner", title: "Ear-side eye corner"),
                Row(key: "noseCorner", title: "Nose-side eye corner"), Row(key: "eyelidTop", title: "Upper eyelid apex"),
                Row(key: "eyelidBottom", title: "Lower eyelid apex"), Row(key: "led", title: "LED glint"),
                Row(key: "filteredLED", title: "Filtered LED glint"), Row(key: "eyeFrame", title: "Eye frame metadata"),
                Row(key: "eyeError", title: "Eye tracker error")]),
            Section(title: "Motion & orientation", note: "Requested sensor rate: Slow (1 Hz fused orientation). Raw accelerometer, gyroscope and magnetometer streams are enabled separately. Simulator sliders supply orientation; raw streams may be absent.", rows: [
                Row(key: "orientation", title: "Head orientation"), Row(key: "quaternion", title: "Quaternion"),
                Row(key: "calibration", title: "IMU calibration"), Row(key: "acc", title: "Accelerometer · m/s²"),
                Row(key: "gyro", title: "Gyroscope · rad/s"), Row(key: "mag", title: "Magnetometer · mGauss"),
                Row(key: "sensorError", title: "Sensor diagnostic")]),
            Section(title: "Camera", note: "AI vision camera capture is disabled. This app never opens or reads the scene camera.", rows: [
                Row(key: "cameraDisabled", title: "Camera capture")]),
            Section(title: "Microphones", note: "Both directional and omni LC3 streams are opened. The directional PCM stream supplies the one-second RMS/peak meter in dBFS; this is not a calibrated sound-pressure reading.", rows: [
                Row(key: "micState", title: "Microphone state"), Row(key: "audioLevel", title: "Directional audio level"),
                Row(key: "directional", title: "Directional throughput"), Row(key: "directionalPackets", title: "Directional packets"),
                Row(key: "omni", title: "Omni throughput"), Row(key: "omniPackets", title: "Omni packets"),
                Row(key: "micError", title: "Microphone error")]),
            Section(title: "Input & system events", note: simulated ? "Proximity is not simulated. Touch and power events can be injected from the simulator dashboard." : "Latest event and total received count for this monitoring session.", rows: [
                Row(key: "touch", title: "Last touch gesture"), Row(key: "powerButton", title: "Last power-button event"),
                Row(key: "device.\(M2DeviceType.ambient.name)", title: "Ambient sensor enabled"),
                Row(key: "device.\(M2DeviceType.prox.name)", title: "Proximity sensor enabled"),
                Row(key: "device.\(M2DeviceType.touch.name)", title: "Touch sensor enabled"),
                Row(key: "systemError", title: "Last system error")])
        ]
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.allowsSelection = false
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        buildHeader()
        connectionListener.changed = { [weak self] in
            DispatchQueue.main.async { self?.connectionChanged() }
        }
        connectionListener.failed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.autoReconnect, self.connectionStarted != nil else { return }
                self.connectionStarted = nil
                self.nextRetry = ProcessInfo.processInfo.systemUptime + self.retryDelay
                self.retryDelay = min(self.retryDelay * 2, 15)
            }
        }
        connectionListener.configured = { [weak self] in
            DispatchQueue.main.async { self?.nextRetry = 0; self?.retryDelay = 1 }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.foreground = false
                self.timer?.invalidate(); self.timer = nil
                self.monitor.stop()
            })
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.foreground = true
                self.nextRetry = 0
                self.startTimer()
                self.refresh()
            })
        // Initialize once; the SDK restores its configured device independently of our UI.
        Evs.shared.doInit()
        initialized = true
        Evs.shared.glassesService.registerConnectionListener(listener: connectionListener)
        restoreSuccessfulTargetIfNeeded()
        startTimer()
        refresh()
    }

    deinit {
        timer?.invalidate()
        notifications.forEach(NotificationCenter.default.removeObserver)
        monitor.stop()
        if initialized { Evs.shared.glassesService.unregisterConnectionListener(listener: connectionListener) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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

    private func connectionChanged() {
        if ready {
            saveSuccessfulTarget()
            retryDelay = 1; nextRetry = 0; connectionStarted = nil
            if foreground && monitoringWanted { monitor.start(); addHUDIfNeeded() }
        } else {
            monitor.stop()
            hud = nil
        }
        // Telemetry is rendered only by the 1 Hz timer, including connection callbacks.
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

    private func refresh() {
        guard initialized, foreground else { return }
        if ready {
            if monitoringWanted && !monitor.isRunning { connectionChanged() }
            monitor.pollStatus()
        } else { reconnectIfNeeded() }
        latest = monitor.snapshot()
        ticks += 1
        let service = Evs.shared.glassesService
        let state = ready ? (monitoringWanted ? "LIVE" : "PAUSED") : service.getConnectionStatus().name.uppercased()
        let target = service.getDeviceName().isEmpty ? "Choose a device to begin" : service.getDeviceName()
        statusLabel.text = "\(state)  ·  \(target)"
        statusLabel.textColor = ready ? (monitoringWanted ? .systemTeal : .systemOrange) : .secondaryLabel
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        cadenceLabel.text = "1 s refresh  ·  \(time)  ·  update \(ticks)\n\(hasKey ? "SDK 0.2.0" : "Developer key missing") · \(service.isSimulatorConfigured() ? "simulated sensors" : "glasses sensors")"
        connectButton.setTitle(service.isConnected() || connectionStarted != nil ? "Disconnect" : "Connect", for: .normal)
        connectButton.isEnabled = hasKey && service.hasConfiguredDevice()
        pauseButton.setTitle(monitoringWanted ? "Pause sensors" : "Resume sensors", for: .normal)
        pauseButton.isEnabled = ready
        reconnectSwitch.isOn = autoReconnect
        updateHUD()
        // Keep scroll position and interaction stable while data changes at 1 Hz.
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            if let cell = tableView.cellForRow(at: indexPath) { configureCell(cell, at: indexPath) }
        }
        // Respect Dynamic Type and orientation without a fixed-height header clipping controls.
        sizeHeader()
    }

    @objc private func configure() {
        nextRetry = .greatestFiniteMagnitude
        connectionStarted = nil
        monitor.stop()
        Evs.shared.glassesService.disconnect()
        autoReconnect = true
        // Configuration UI connects the selected target. A later Configure callback releases the retry hold.
        Evs.shared.showAppUI(option: M2AppUIOption.companion.DefaultConfigure)
    }
    @objc private func toggleConnection() {
        let service = Evs.shared.glassesService
        if service.isConnected() || connectionStarted != nil {
            autoReconnect = false
            connectionStarted = nil
            monitor.stop()
            service.disconnect()
        } else {
            autoReconnect = true
            nextRetry = 0; retryDelay = 1
            reconnectIfNeeded()
        }
        refresh()
    }
    @objc private func toggleMonitoring() {
        monitoringWanted.toggle()
        if monitoringWanted && ready { monitor.start() } else { monitor.stop() }
        refresh()
    }
    @objc private func toggleReconnect() {
        autoReconnect = reconnectSwitch.isOn
        nextRetry = 0; retryDelay = 1
        if !autoReconnect { connectionStarted = nil }
    }

    private func buildHeader() {
        let heading = UILabel()
        heading.text = "Sensor status"
        heading.font = .preferredFont(forTextStyle: .largeTitle)
        heading.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        cadenceLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cadenceLabel.textColor = .secondaryLabel
        cadenceLabel.numberOfLines = 0
        configureButton.setTitle("Configure", for: .normal)
        configureButton.addTarget(self, action: #selector(configure), for: .touchUpInside)
        connectButton.addTarget(self, action: #selector(toggleConnection), for: .touchUpInside)
        pauseButton.addTarget(self, action: #selector(toggleMonitoring), for: .touchUpInside)
        for button in [configureButton, connectButton, pauseButton] { button.configuration = .tinted() }
        let controls = UIStackView(arrangedSubviews: [configureButton, connectButton])
        controls.axis = .horizontal; controls.distribution = .fillEqually; controls.spacing = 10
        let reconnectLabel = UILabel()
        reconnectLabel.text = "Auto reconnect"
        reconnectLabel.font = .preferredFont(forTextStyle: .body)
        reconnectSwitch.accessibilityLabel = "Auto reconnect"
        reconnectSwitch.isOn = autoReconnect
        reconnectSwitch.addTarget(self, action: #selector(toggleReconnect), for: .valueChanged)
        let reconnect = UIStackView(arrangedSubviews: [reconnectLabel, reconnectSwitch])
        reconnect.axis = .horizontal; reconnect.alignment = .center
        let note = UILabel()
        note.text = "Reads motion, eye tracking, microphones and device sensors while active. Camera capture is disabled. Pause stops collection."
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel; note.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [heading, statusLabel, cadenceLabel, controls, pauseButton, reconnect, note])
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView()
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12)
        ])
        tableView.tableHeaderView = header
    }
    private func sizeHeader() {
        guard let header = tableView.tableHeaderView else { return }
        let height = header.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        if abs(header.frame.height - height) > 1 {
            header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
            tableView.tableHeaderView = header
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); sizeHeader() }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].note }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reading") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "reading")
        configureCell(cell, at: indexPath)
        return cell
    }
    private func configureCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        let row = sections[indexPath.section].rows[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        if row.key == "cameraDisabled" {
            content.secondaryText = "Disabled · not activated"
        } else if let reading = latest?.readings[row.key], let snapshot = latest {
            let age = max(0, snapshot.capturedAt - reading.receivedAt)
            let timestamp = reading.deviceTimestamp.map { " · device \($0) ms" } ?? ""
            let streaming = ["acc", "gyro", "mag", "quaternion", "orientation", "eyeValid", "pupilVisibility", "pupilCenter", "iris", "pupil", "audioLevel"].contains(row.key)
            let stale = age > 3 && monitor.isRunning && streaming ? " · STALE" : ""
            let value = monitor.isRunning ? reading.value : "Last: " + reading.value
            content.secondaryText = value + String(format: "\n%.1f s ago · %d samples", age, reading.count) + timestamp + stale
        } else if row.key.lowercased().contains("error") {
            content.secondaryText = "No errors reported"
        } else if isSimulator && row.key == "proximity" {
            content.secondaryText = "Unavailable in simulator"
        } else if isSimulator && ["eyeValid", "pupilVisibility", "pupilCenter", "iris", "pupil", "earCorner", "noseCorner", "eyelidTop", "eyelidBottom", "led", "filteredLED", "eyeFrame"].contains(row.key) {
            content.secondaryText = "Waiting for eye-tracker feature frames…"
        } else {
            content.secondaryText = monitor.isRunning ? "Waiting for sensor data…" : "No samples · sensors paused or disconnected"
        }
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "sensor.\(row.key)"
    }

    private func addHUDIfNeeded() {
        guard ready, hud == nil else { return }
        let screen = StatusHUD()
        hud = screen
        Evs.shared.screenService.addScreen(screen: screen)
    }
    private func updateHUD() {
        guard ready else { return }
        addHUDIfNeeded()
        let values = latest?.readings ?? [:]
        hud?.update([
            monitoringWanted ? "Sensor status • 1s" : "Sensor status • paused",
            "Battery " + (values["battery"]?.value ?? "—") + "  Light " + (values["ambient"]?.value ?? "—"),
            values["orientation"]?.value ?? "Waiting for orientation",
            "Eye " + (values["eyeState"]?.value ?? "—") + "  Pupil " + (values["pupilVisibility"]?.value ?? "—")
        ])
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
    private final class StatusHUD: M2Screen {
        private var lines: [M2Text] = []
        init() { super.init(width: 540, height: 280, tag: "sensor-status") }
        override func onCreate() {
            lines.removeAll()
            for index in 0..<4 {
                let text = M2Text(text: "", tag: "status-line-\(index)")
                _ = text.setXY(x: 18, y: Float(42 + index * 52))
                _ = text.setColor(evsColor: index == 0 ? .green : .white)
                _ = text.setScale(scale: 0.7)
                _ = add(drawable: text)
                lines.append(text)
            }
        }
        func update(_ values: [String]) {
            for (text, value) in zip(lines, values) { _ = text.setText(text: value) }
        }
    }
}
