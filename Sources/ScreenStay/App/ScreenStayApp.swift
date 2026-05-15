import AppKit
import IOKit.ps

final class RestlessApp: NSObject, NSApplicationDelegate {
    private let toggleController = SleepToggleController()
    private let launchAtLoginController = LaunchAtLoginController()
    private var statusItem: NSStatusItem?
    private var monitorTimer: Timer?
    private var limitTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var isAutomaticSleepInProgress = false
    private var requestedSleepDisabled: Bool?
    private var isSleepToggleCommandRunning = false
    private var onboardingWindowController: OnboardingWindowController?
    private weak var visibleHeaderView: HeaderMenuItemView?
    private weak var visibleStatusRowView: StatusRowView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        toggleController.refresh()
        toggleController.refreshPasswordlessSetupStatus()
        runMonitoringPass(enforceLimits: false)
        startMonitoring()
        startSystemEventMonitoring()
        showOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitorTimer?.invalidate()
        limitTimer?.invalidate()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        statusItem = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showMenu()
    }

    @objc private func toggleFromMenu(_ sender: Any) {
        let requestedEnabled = (sender as? MenuSwitchControl)?.isOn ?? !effectiveEnabled
        setSleepDisabled(requestedEnabled)
    }

    @objc private func chooseSessionLimit(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        toggleController.sessionLimitMinutes = minutes
        handleSettingsChange()
        reopenMenuSoon()
    }

    @objc private func chooseBatteryFloor(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        toggleController.batteryFloorPercent = percent
        handleSettingsChange()
        reopenMenuSoon()
    }

    @objc private func chooseCustomSessionLimit(_ sender: NSMenuItem) {
        guard let minutes = promptForCustomSessionLimit() else { return }

        toggleController.sessionLimitMinutes = minutes
        handleSettingsChange()
    }

    @objc private func chooseCustomBatteryFloor(_ sender: NSMenuItem) {
        guard let percent = promptForCustomBatteryFloor() else { return }

        toggleController.batteryFloorPercent = percent
        handleSettingsChange()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any) {
        do {
            let requestedEnabled = (sender as? ToggleMenuItemView)?.isOn ?? !launchAtLoginController.isEnabled
            try launchAtLoginController.setEnabled(requestedEnabled)
            (sender as? ToggleMenuItemView)?.isOn = launchAtLoginController.isEnabled
            reopenMenuSoon()
        } catch {
            presentError(error, title: "Restless could not update startup")
        }
    }

    @objc private func installPasswordlessFromMenu(_ sender: Any) {
        updateStatusItem(isWorking: true)

        toggleController.installPasswordlessToggle { [weak self] result in
            guard let self else { return }
            self.runMonitoringPass(enforceLimits: true)

            if case .failure(let error) = result {
                self.presentError(error, title: "Restless could not finish setup")
            }
        }
    }

    private func setSleepDisabled(_ enabled: Bool) {
        requestedSleepDisabled = enabled
        updateStatusItem()
        refreshVisibleMenu()
        runNextSleepToggleCommandIfNeeded()
    }

    private func runNextSleepToggleCommandIfNeeded() {
        guard !isSleepToggleCommandRunning, let requestedSleepDisabled else { return }

        isSleepToggleCommandRunning = true
        let commandEnabled = requestedSleepDisabled

        toggleController.setSleepDisabled(commandEnabled) { [weak self] result in
            guard let self else { return }
            self.isSleepToggleCommandRunning = false

            guard self.requestedSleepDisabled == commandEnabled else {
                self.updateStatusItem()
                self.refreshVisibleMenu()
                self.runNextSleepToggleCommandIfNeeded()
                return
            }

            self.requestedSleepDisabled = nil
            self.runMonitoringPass(enforceLimits: true)

            if case .failure(let error) = result {
                self.presentError(error, title: "Restless could not change sleep")
            }
        }
    }

    private func enterClosedLidSleepAfterLimit() {
        limitTimer?.invalidate()
        updateStatusItem(isWorking: true)

        toggleController.pauseForClosedLidLimit { [weak self] result in
            guard let self else { return }
            self.runMonitoringPass(enforceLimits: false)

            switch result {
            case .success:
                self.toggleController.requestSystemSleep()
            case .failure(let error):
                self.presentError(error, title: "Restless could not change sleep")
            }

            self.isAutomaticSleepInProgress = false
        }
    }

    private func startMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.runMonitoringPass(enforceLimits: true)
        }
    }

    private func startSystemEventMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemStateChanged(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemStateChanged(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemStateChanged(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemStateChanged(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let app = Unmanaged<RestlessApp>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                app.runMonitoringPass(enforceLimits: true)
            }
        }, context)?.takeRetainedValue() else {
            return
        }

        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    @objc private func systemStateChanged(_ notification: Notification) {
        runMonitoringPass(enforceLimits: true)
    }

    private func handleSettingsChange() {
        runMonitoringPass(enforceLimits: true)
    }

    private func showOnboardingIfNeeded() {
        if UserDefaults.standard.bool(forKey: "restless.onboardingComplete"),
           toggleController.isPasswordlessSetupInstalled,
           launchAtLoginController.isEnabled {
            return
        }

        if toggleController.isPasswordlessSetupInstalled,
           launchAtLoginController.isEnabled {
            UserDefaults.standard.set(true, forKey: "restless.onboardingComplete")
            return
        }

        showOnboarding()
    }

    private func showOnboarding() {
        if let onboardingWindowController {
            onboardingWindowController.show()
            return
        }

        let controller = OnboardingWindowController(
            isLaunchAtLoginEnabled: launchAtLoginController.isEnabled,
            isPasswordlessInstalled: toggleController.isPasswordlessSetupInstalled,
            setLaunchAtLogin: { [weak self] enabled in
                self?.setLaunchAtLoginForOnboarding(enabled) ?? .failure("Restless could not update startup.")
            },
            runSetup: { [weak self] completion in
                self?.runFirstRunSetup(completion: completion)
            },
            finish: { [weak self] in
                UserDefaults.standard.set(true, forKey: "restless.onboardingComplete")
                self?.onboardingWindowController?.close()
                self?.onboardingWindowController = nil
            }
        )
        onboardingWindowController = controller
        controller.show()
    }

    private func setLaunchAtLoginForOnboarding(_ enabled: Bool) -> OnboardingActionResult {
        do {
            try launchAtLoginController.setEnabled(enabled)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func runFirstRunSetup(completion: @escaping (OnboardingSetupResult) -> Void) {
        guard !toggleController.isPasswordlessSetupInstalled else {
            UserDefaults.standard.set(true, forKey: "restless.onboardingComplete")
            runMonitoringPass(enforceLimits: true)
            completion(
                .success(
                    launchAtLoginEnabled: launchAtLoginController.isEnabled,
                    passwordlessInstalled: toggleController.isPasswordlessSetupInstalled
                )
            )
            return
        }

        toggleController.installPasswordlessToggle { [weak self] result in
            guard let self else { return }
            self.runMonitoringPass(enforceLimits: true)

            switch result {
            case .success:
                UserDefaults.standard.set(true, forKey: "restless.onboardingComplete")
                completion(
                    .success(
                        launchAtLoginEnabled: self.launchAtLoginController.isEnabled,
                        passwordlessInstalled: self.toggleController.isPasswordlessSetupInstalled
                    )
                )
            case .failure(let error):
                completion(.failure(error.localizedDescription))
            }
        }
    }

    private func runMonitoringPass(enforceLimits: Bool) {
        toggleController.monitor()
        updateStatusItem()
        refreshVisibleMenu()
        scheduleLimitTimer()

        if toggleController.shouldResumeAfterClosedLidSleep {
            toggleController.markResumingAfterClosedLidSleep()
            setSleepDisabled(true)
            return
        }

        if requestedSleepDisabled == nil,
           !isSleepToggleCommandRunning,
           toggleController.shouldReapplyDesiredKeepAwake {
            setSleepDisabled(true)
            return
        }

        if enforceLimits && toggleController.shouldStopForLimit && !isAutomaticSleepInProgress {
            isAutomaticSleepInProgress = true
            enterClosedLidSleepAfterLimit()
        }
    }

    private func scheduleLimitTimer() {
        limitTimer?.invalidate()
        limitTimer = nil

        guard toggleController.shouldScheduleCloseLimitTimer else { return }

        let interval = max(1, toggleController.closedLimitRemainingSeconds)
        limitTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.runMonitoringPass(enforceLimits: true)
        }
    }

    private func updateStatusItem(isWorking: Bool = false) {
        guard let button = statusItem?.button else { return }

        statusItem?.length = NSStatusItem.squareLength

        button.wantsLayer = true
        button.layer?.cornerRadius = 0
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = nil
        button.layer?.sublayers = nil
        button.image = statusItemImage(tintColor: statusIconTintColor)
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = nil
        button.alphaValue = 1.0
        button.toolTip = statusToolTip
    }

    private func statusItemImage(tintColor: NSColor?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: "Restless")?
            .withSymbolConfiguration(configuration)
        else {
            return nil
        }

        let image = NSImage(size: NSSize(width: 22, height: 20))
        image.lockFocus()

        let drawRect = NSRect(x: 1, y: 1.15, width: 20, height: 16.75)
        let drawnSymbol = tintColor
            .flatMap { symbol.withSymbolConfiguration(.init(hierarchicalColor: $0)) }
            ?? symbol
        drawnSymbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        image.unlockFocus()
        image.isTemplate = tintColor == nil
        return image
    }

    private var statusIconTintColor: NSColor? {
        if shouldShowWarningState {
            return .systemOrange
        }

        if effectiveEnabled {
            return .systemBlue
        }

        return nil
    }

    private var effectiveEnabled: Bool {
        requestedSleepDisabled ?? toggleController.isEnabled
    }

    private var statusToolTip: String {
        guard requestedSleepDisabled != nil || toggleController.isStatusKnown else {
            return "Restless: checking sleep status"
        }

        if isPausedByBatteryCutoff {
            return "Restless paused: battery is at or below the \(batteryLimitTitle()) cutoff."
        }

        if isPausedAfterClosedLidLimit {
            return "Restless paused: closed-lid limit reached. It will re-arm when the lid opens."
        }

        return effectiveEnabled ? "Restless on: sleep disabled" : "Restless off: normal sleep"
    }

    private func showMenu() {
        toggleController.monitor()

        let menu = NSMenu()

        menu.addItem(headerMenuItem())
        menu.addItem(.separator())
        menu.addItem(sectionHeaderItem("Status"))
        menu.addItem(statusSummaryItem())

        if let remaining = toggleController.closedLimitRemainingText {
            menu.addItem(remainingTimeItem(remaining))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeaderItem("Limits"))
        menu.addItem(timeLimitMenu())
        menu.addItem(batteryLimitMenu())
        menu.addItem(.separator())
        menu.addItem(sectionHeaderItem("Settings"))
        menu.addItem(launchAtLoginMenuItem())

        if !toggleController.isPasswordlessSetupInstalled {
            menu.addItem(.separator())
            menu.addItem(sectionHeaderItem("Setup"))
            menu.addItem(passwordlessSetupMenuItem())
        }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func reopenMenuSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.showMenu()
        }
    }

    private func headerMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = HeaderMenuItemView(
            title: "Restless",
            detail: headerSubtitle,
            isEnabled: effectiveEnabled,
            target: self,
            action: #selector(toggleFromMenu(_:))
        )
        visibleHeaderView = view
        item.view = view
        return item
    }

    private var headerSubtitle: String {
        ""
    }

    private func sectionHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SectionHeaderView(title: title)
        return item
    }

    private func statusSummaryItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = StatusRowView(
            symbolName: "display",
            accentColor: statusAccentColor,
            title: statusTitle,
            subtitle: statusDetail,
            trailing: toggleController.batteryPercent.map { "\($0)%" }
        )
        visibleStatusRowView = view
        item.view = view
        return item
    }

    private func remainingTimeItem(_ remaining: String) -> NSMenuItem {
        let metric = splitMenuMetric(remaining)
        let item = NSMenuItem()
        item.view = StatusRowView(
            symbolName: "timer",
            accentColor: .tertiaryLabelColor,
            title: metric.title,
            subtitle: metric.detail,
            trailing: nil
        )
        return item
    }

    private var statusTitle: String {
        guard requestedSleepDisabled != nil || toggleController.isStatusKnown else {
            return "Checking status"
        }

        if isPausedByBatteryCutoff {
            return "Battery too low"
        }

        if isPausedAfterClosedLidLimit {
            return "Close limit reached"
        }

        return effectiveEnabled ? "Preventing sleep" : "Normal sleep"
    }

    private var statusDetail: String {
        if let requestedSleepDisabled {
            return requestedSleepDisabled ? "Applying keep-awake..." : "Restoring normal sleep..."
        }

        if isPausedByBatteryCutoff {
            return "At/below \(batteryLimitTitle()); keep-awake paused"
        }

        if isPausedAfterClosedLidLimit {
            return "Will re-arm when the lid opens"
        }

        return toggleController.closedSessionMetricsTitle ?? "No closed session yet"
    }

    private var statusAccentColor: NSColor {
        if shouldShowWarningState {
            return .systemOrange
        }

        return effectiveEnabled ? .systemBlue : .tertiaryLabelColor
    }

    private func refreshVisibleMenu() {
        visibleHeaderView?.configure(detail: headerSubtitle, isEnabled: effectiveEnabled)
        visibleStatusRowView?.configure(
            accentColor: statusAccentColor,
            title: statusTitle,
            subtitle: statusDetail,
            trailing: toggleController.batteryPercent.map { "\($0)%" }
        )
    }

    private var isPausedByBatteryCutoff: Bool {
        effectiveEnabled && toggleController.isBatteryCutoffReached
    }

    private var isPausedAfterClosedLidLimit: Bool {
        effectiveEnabled && toggleController.isWaitingForNextLidOpen
    }

    private var shouldShowWarningState: Bool {
        effectiveEnabled && (toggleController.isBatteryCutoffReached || toggleController.isWaitingForNextLidOpen)
    }

    private func splitMenuMetric(_ value: String) -> (title: String, detail: String) {
        guard let separator = value.firstIndex(of: ":") else {
            return (value, "")
        }

        let title = String(value[..<separator])
        let detailStart = value.index(after: separator)
        let detail = value[detailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, detail)
    }

    private func launchAtLoginMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ToggleMenuItemView(
            title: "Start at Login",
            symbolName: "arrow.clockwise",
            isOn: launchAtLoginController.isEnabled,
            target: self,
            action: #selector(toggleLaunchAtLogin(_:))
        )
        return item
    }

    private func passwordlessSetupMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = PasswordlessSetupMenuItemView(
            target: self,
            action: #selector(installPasswordlessFromMenu(_:))
        )
        return item
    }

    private func timeLimitMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Close Timer: \(timeLimitTitle())", action: nil, keyEquivalent: "")
        item.image = menuImage("timer")
        let submenu = NSMenu()
        for menuItem in sessionLimitItems() {
            submenu.addItem(menuItem)
        }

        item.submenu = submenu
        return item
    }

    private func batteryLimitMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Battery Cutoff: \(batteryLimitTitle())", action: nil, keyEquivalent: "")
        item.image = menuImage("battery.50")
        let submenu = NSMenu()
        for menuItem in batteryFloorItems() {
            submenu.addItem(menuItem)
        }

        item.submenu = submenu
        return item
    }

    private func timeLimitTitle() -> String {
        switch toggleController.sessionLimitMinutes {
        case 0:
            return "Off"
        case 60:
            return "1 hour"
        case 120:
            return "2 hours"
        default:
            return "\(toggleController.sessionLimitMinutes) min"
        }
    }

    private func batteryLimitTitle() -> String {
        toggleController.batteryFloorPercent == 0 ? "Off" : "\(toggleController.batteryFloorPercent)%"
    }

    private func sessionLimitItems() -> [NSMenuItem] {
        let submenu = NSMenu()
        let presets = [0, 15, 30, 60, 120]

        for option in presets {
            let title: String
            switch option {
            case 0:
                title = "Off"
            case 60:
                title = "1 hour"
            case 120:
                title = "2 hours"
            default:
                title = "\(option) min"
            }

            let menuItem = NSMenuItem(title: title, action: #selector(chooseSessionLimit(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = option
            menuItem.state = toggleController.sessionLimitMinutes == option ? .on : .off
            submenu.addItem(menuItem)
        }

        let customTitle = presets.contains(toggleController.sessionLimitMinutes)
            ? "Custom..."
            : "Custom: \(timeLimitTitle())..."
        let customItem = NSMenuItem(title: customTitle, action: #selector(chooseCustomSessionLimit(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = presets.contains(toggleController.sessionLimitMinutes) ? .off : .on
        submenu.addItem(customItem)

        return submenu.items
    }

    private func menuImage(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func batteryFloorItems() -> [NSMenuItem] {
        let submenu = NSMenu()
        let presets = [0, 10, 20, 40, 60]

        for option in presets {
            let title = option == 0 ? "Off" : "\(option)%"
            let menuItem = NSMenuItem(title: title, action: #selector(chooseBatteryFloor(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = option
            menuItem.state = toggleController.batteryFloorPercent == option ? .on : .off
            submenu.addItem(menuItem)
        }

        let customTitle = presets.contains(toggleController.batteryFloorPercent)
            ? "Custom..."
            : "Custom: \(batteryLimitTitle())..."
        let customItem = NSMenuItem(title: customTitle, action: #selector(chooseCustomBatteryFloor(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = presets.contains(toggleController.batteryFloorPercent) ? .off : .on
        submenu.addItem(customItem)

        return submenu.items
    }

    private func promptForCustomSessionLimit() -> Int? {
        NSApp.activate(ignoringOtherApps: true)

        let content = CustomTimePanelContent(
            minutes: max(toggleController.sessionLimitMinutes, 30)
        )
        return runCustomPanel(title: "Close Timer", content: content) {
            content.validatedMinutes
        }
    }

    private func promptForCustomBatteryFloor() -> Int? {
        NSApp.activate(ignoringOtherApps: true)

        let content = CustomPercentPanelContent(
            label: "Sleep at or below",
            percent: max(toggleController.batteryFloorPercent, 40)
        )
        return runCustomPanel(title: "Battery Cutoff", content: content) {
            content.validatedPercent
        }
    }

    private func runCustomPanel<Value>(
        title: String,
        content: CustomPanelContentView,
        value: () -> Value?
    ) -> Value? {
        let panel = CompactInputPanel(title: title, contentView: content)

        guard panel.runModal() else { return nil }
        guard let value = value() else {
            presentError(
                RestlessError.commandFailed(content.validationMessage),
                title: "Restless could not save that value"
            )
            return nil
        }

        return value
    }

    private func presentError(_ error: Error, title: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private class CustomPanelContentView: NSView {
    var validationMessage: String {
        "Enter a valid value."
    }

    func focus() {}
}

private final class CompactInputPanel: NSObject {
    private let panel: NSPanel
    private let customContent: CustomPanelContentView

    init(title: String, contentView customContent: CustomPanelContentView) {
        self.customContent = customContent
        let width: CGFloat = 286
        let height = customContent.frame.height + 84
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        customContent.frame.origin = NSPoint(x: 18, y: 62)
        root.addSubview(customContent)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: width - 184, y: 18, width: 78, height: 28)
        root.addSubview(cancelButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: width - 96, y: 18, width: 78, height: 28)
        root.addSubview(saveButton)

        panel.contentView = root
        panel.defaultButtonCell = saveButton.cell as? NSButtonCell
    }

    func runModal() -> Bool {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        customContent.focus()
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response == .OK
    }

    @objc private func save() {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel() {
        NSApp.stopModal(withCode: .cancel)
    }
}

private final class CustomTimePanelContent: CustomPanelContentView {
    private let hoursField = NSTextField()
    private let minutesField = NSTextField()

    override var validationMessage: String {
        "Enter a time from 1 minute to 12 hours."
    }

    var validatedMinutes: Int? {
        let hours = max(0, hoursField.integerValue)
        let minutes = max(0, minutesField.integerValue)
        let total = hours * 60 + minutes
        guard total >= 1, total <= 720, minutes <= 59 else { return nil }
        return total
    }

    init(minutes: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 62))

        let clamped = min(max(minutes, 1), 720)
        let hours = clamped / 60
        let remainder = clamped % 60

        let label = NSTextField(labelWithString: "Stay awake after lid closes")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 0, y: 44, width: 250, height: 16)
        addSubview(label)

        configureNumberField(hoursField, value: hours)
        hoursField.frame = NSRect(x: 0, y: 14, width: 58, height: 24)
        addSubview(hoursField)

        let hoursLabel = unitLabel("hr", x: 64)
        addSubview(hoursLabel)

        configureNumberField(minutesField, value: remainder)
        minutesField.frame = NSRect(x: 104, y: 14, width: 58, height: 24)
        addSubview(minutesField)

        let minutesLabel = unitLabel("min", x: 168)
        addSubview(minutesLabel)

        let hint = NSTextField(labelWithString: "Max 12 hr")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 0, width: 250, height: 13)
        addSubview(hint)
    }

    override func focus() {
        window?.makeFirstResponder(hoursField)
        hoursField.selectText(nil)
    }

    private func configureNumberField(_ field: NSTextField, value: Int) {
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.integerValue = value
    }

    private func unitLabel(_ text: String, x: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: 17, width: 34, height: 16)
        return label
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class CustomPercentPanelContent: CustomPanelContentView {
    private let percentField = NSTextField()

    override var validationMessage: String {
        "Enter a battery percentage from 1 to 99."
    }

    var validatedPercent: Int? {
        let percent = percentField.integerValue
        guard percent >= 1, percent <= 99 else { return nil }
        return percent
    }

    init(label: String, percent: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 52))

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 0, y: 34, width: 250, height: 16)
        addSubview(titleLabel)

        percentField.frame = NSRect(x: 0, y: 4, width: 64, height: 24)
        percentField.alignment = .right
        percentField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        percentField.integerValue = min(max(percent, 1), 99)
        addSubview(percentField)

        let percentLabel = NSTextField(labelWithString: "%")
        percentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.frame = NSRect(x: 72, y: 7, width: 22, height: 16)
        addSubview(percentLabel)
    }

    override func focus() {
        window?.makeFirstResponder(percentField)
        percentField.selectText(nil)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class HeaderMenuItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let toggle = MenuSwitchControl(frame: NSRect(x: 224, y: 6, width: 52, height: 28))

    init(title: String, detail: String, isEnabled: Bool, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 40))

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 18, y: 9, width: 168, height: 22)
        addSubview(titleLabel)

        toggle.target = target
        toggle.action = action
        addSubview(toggle)

        configure(detail: detail, isEnabled: isEnabled)
    }

    func configure(detail: String, isEnabled: Bool) {
        toggle.isOn = isEnabled
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class MenuSwitchControl: NSSwitch {
    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }
}

private final class SectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 22))

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 18, y: 2, width: 256, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class StatusRowView: NSView {
    private let iconBackground = NSView(frame: NSRect(x: 18, y: 8, width: 34, height: 34))
    private let icon = NSImageView(frame: NSRect(x: 25, y: 15, width: 20, height: 20))
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")

    init(symbolName: String, accentColor: NSColor, title: String, subtitle: String, trailing: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 50))

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 17
        addSubview(iconBackground)

        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 64, y: 8, width: 210, height: 15)
        addSubview(subtitleLabel)

        trailingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        trailingLabel.textColor = .secondaryLabelColor
        trailingLabel.alignment = .right
        trailingLabel.frame = NSRect(x: 210, y: 25, width: 64, height: 18)
        addSubview(trailingLabel)

        configure(accentColor: accentColor, title: title, subtitle: subtitle, trailing: trailing)
    }

    func configure(accentColor: NSColor, title: String, subtitle: String, trailing: String?) {
        iconBackground.layer?.backgroundColor = accentColor.withAlphaComponent(0.18).cgColor
        icon.contentTintColor = accentColor
        titleLabel.stringValue = title
        titleLabel.frame = NSRect(x: 64, y: 25, width: trailing == nil ? 210 : 152, height: 18)
        subtitleLabel.stringValue = subtitle
        trailingLabel.stringValue = trailing ?? ""
        trailingLabel.isHidden = trailing == nil
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class ToggleMenuItemView: NSControl {
    private let iconView = NSImageView()
    private let toggle = MenuSwitchControl(frame: NSRect(x: 228, y: 4, width: 44, height: 24))

    var isOn: Bool {
        didSet {
            toggle.isOn = isOn
        }
    }

    init(title: String, symbolName: String, isOn: Bool, target: AnyObject, action: Selector) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 32))

        self.target = target
        self.action = action

        iconView.frame = NSRect(x: 20, y: 7, width: 18, height: 18)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        iconView.contentTintColor = .labelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 52, y: 7, width: 184, height: 18)
        addSubview(titleLabel)

        toggle.isOn = isOn
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        addSubview(toggle)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        _ = target?.perform(action, with: self)
    }

    @objc private func toggleChanged(_ sender: MenuSwitchControl) {
        isOn = sender.isOn
        _ = target?.perform(action, with: self)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class PasswordlessSetupMenuItemView: NSView {
    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 78))

        let iconBackground = NSView(frame: NSRect(x: 18, y: 22, width: 34, height: 34))
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 17
        iconBackground.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.2).cgColor
        addSubview(iconBackground)

        let icon = NSImageView(frame: NSRect(x: 26, y: 30, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "Allow Restless")
        icon.contentTintColor = .systemBlue
        addSubview(icon)

        let titleLabel = NSTextField(labelWithString: "One-time setup")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 64, y: 50, width: 210, height: 16)
        addSubview(titleLabel)

        let messageLabel = NSTextField(labelWithString: "Allow passwordless keep-awake toggles.")
        messageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.frame = NSRect(x: 64, y: 34, width: 210, height: 15)
        addSubview(messageLabel)

        let button = NSButton(title: "Allow Restless", target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.frame = NSRect(x: 64, y: 7, width: 112, height: 24)
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
