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

    @objc private func toggleFromMenu(_ sender: NSMenuItem) {
        setSleepDisabled(!toggleController.isEnabled)
    }

    @objc private func chooseSessionLimit(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        toggleController.sessionLimitMinutes = minutes
        handleSettingsChange()
    }

    @objc private func chooseBatteryFloor(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        toggleController.batteryFloorPercent = percent
        handleSettingsChange()
    }

    @objc private func chooseCustomSessionLimit(_ sender: NSMenuItem) {
        guard let minutes = promptForInteger(
            title: "Custom Time Limit",
            message: "Minutes to stay awake after the lid closes:",
            defaultValue: max(toggleController.sessionLimitMinutes, 30),
            minimum: 1,
            maximum: 720,
            unit: "minutes"
        ) else { return }

        toggleController.sessionLimitMinutes = minutes
        handleSettingsChange()
    }

    @objc private func chooseCustomBatteryFloor(_ sender: NSMenuItem) {
        guard let percent = promptForInteger(
            title: "Custom Battery Limit",
            message: "Battery percent where Restless should turn off:",
            defaultValue: max(toggleController.batteryFloorPercent, 40),
            minimum: 1,
            maximum: 99,
            unit: "percent"
        ) else { return }

        toggleController.batteryFloorPercent = percent
        handleSettingsChange()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try launchAtLoginController.setEnabled(!launchAtLoginController.isEnabled)
        } catch {
            presentError(error, title: "Restless could not update startup")
        }
    }

    @objc private func installPasswordlessFromMenu(_ sender: Any) {
        statusItem?.menu?.cancelTracking()
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
        updateStatusItem(isWorking: true)

        toggleController.setSleepDisabled(enabled) { [weak self] result in
            guard let self else { return }
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

    private func runMonitoringPass(enforceLimits: Bool) {
        toggleController.monitor()
        updateStatusItem()
        scheduleLimitTimer()

        if toggleController.shouldResumeAfterClosedLidSleep {
            toggleController.markResumingAfterClosedLidSleep()
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

        button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Restless")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "Restless")
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = toggleController.shouldUseWarningIcon ? .systemOrange : nil
        button.alphaValue = isWorking || toggleController.isEnabled ? 1.0 : 0.62
        button.toolTip = statusToolTip
    }

    private var statusToolTip: String {
        guard toggleController.isStatusKnown else {
            return "Restless: checking sleep status"
        }

        if toggleController.isBatteryCutoffReached {
            return "Restless on: battery cutoff reached"
        }

        if toggleController.isWaitingForNextLidOpen {
            return "Restless on: sleeping until lid opens"
        }

        return toggleController.isEnabled ? "Restless on: sleep disabled" : "Restless off: normal sleep"
    }

    private func showMenu() {
        toggleController.monitor()

        let menu = NSMenu()

        menu.addItem(headerMenuItem())

        if let metricsTitle = toggleController.closedSessionMetricsTitle {
            menu.addItem(disabledItem(metricsTitle))
        }

        if let remaining = toggleController.closedLimitRemainingText {
            menu.addItem(disabledItem(remaining))
        }
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: toggleController.isEnabled ? "Turn Off" : "Turn On",
            action: #selector(toggleFromMenu(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        menu.addItem(timeLimitMenu())
        menu.addItem(batteryLimitMenu())
        menu.addItem(launchAtLoginMenuItem())

        if !toggleController.isPasswordlessSetupInstalled {
            menu.addItem(.separator())
            menu.addItem(passwordlessSetupMenuItem())
        }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func headerMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = HeaderMenuItemView(
            title: "Restless",
            detail: toggleController.batteryPercent.map { "\($0)%" }
        )
        return item
    }

    private func launchAtLoginMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        item.target = self
        item.state = launchAtLoginController.isEnabled ? .on : .off
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

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func timeLimitMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Close Timer: \(timeLimitTitle())", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for menuItem in sessionLimitItems() {
            submenu.addItem(menuItem)
        }

        item.submenu = submenu
        return item
    }

    private func batteryLimitMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Battery Cutoff: \(batteryLimitTitle())", action: nil, keyEquivalent: "")
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
        default:
            return "\(toggleController.sessionLimitMinutes) min"
        }
    }

    private func batteryLimitTitle() -> String {
        toggleController.batteryFloorPercent == 0 ? "Off" : "\(toggleController.batteryFloorPercent)%"
    }

    private func sessionLimitItems() -> [NSMenuItem] {
        let submenu = NSMenu()

        for option in [0, 15, 30, 60] {
            let title: String
            switch option {
            case 0:
                title = "Off"
            case 60:
                title = "1 hour"
            default:
                title = "\(option) min"
            }

            let menuItem = NSMenuItem(title: title, action: #selector(chooseSessionLimit(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = option
            menuItem.state = toggleController.sessionLimitMinutes == option ? .on : .off
            submenu.addItem(menuItem)
        }

        let customItem = NSMenuItem(title: "Custom...", action: #selector(chooseCustomSessionLimit(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = [0, 15, 30, 60].contains(toggleController.sessionLimitMinutes) ? .off : .on
        submenu.addItem(customItem)

        return submenu.items
    }

    private func batteryFloorItems() -> [NSMenuItem] {
        let submenu = NSMenu()

        for option in [0, 20, 40] {
            let title = option == 0 ? "Off" : "\(option)%"
            let menuItem = NSMenuItem(title: title, action: #selector(chooseBatteryFloor(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = option
            menuItem.state = toggleController.batteryFloorPercent == option ? .on : .off
            submenu.addItem(menuItem)
        }

        let customItem = NSMenuItem(title: "Custom...", action: #selector(chooseCustomBatteryFloor(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = [0, 20, 40].contains(toggleController.batteryFloorPercent) ? .off : .on
        submenu.addItem(customItem)

        return submenu.items
    }

    private func promptForInteger(
        title: String,
        message: String,
        defaultValue: Int,
        minimum: Int,
        maximum: Int,
        unit: String
    ) -> Int? {
        NSApp.activate(ignoringOtherApps: true)

        let field = NSTextField(string: "\(defaultValue)")
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        field.alignment = .right

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(message) Enter \(minimum)-\(maximum) \(unit)."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        field.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= minimum, value <= maximum else {
            presentError(
                RestlessError.commandFailed("Enter a whole number from \(minimum) to \(maximum)."),
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

private final class HeaderMenuItemView: NSView {
    init(title: String, detail: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 34))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 18, y: 8, width: 140, height: 18)
        addSubview(titleLabel)

        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .right
            detailLabel.frame = NSRect(x: 158, y: 8, width: 74, height: 18)
            addSubview(detailLabel)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class PasswordlessSetupMenuItemView: NSView {
    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 72))

        let titleLabel = NSTextField(labelWithString: "One-time setup")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 18, y: 46, width: 214, height: 16)
        addSubview(titleLabel)

        let messageLabel = NSTextField(labelWithString: "Stop asking for your password.")
        messageLabel.font = .systemFont(ofSize: 11, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.frame = NSRect(x: 18, y: 29, width: 214, height: 15)
        addSubview(messageLabel)

        let button = NSButton(title: "Allow Restless", target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.frame = NSRect(x: 18, y: 4, width: 112, height: 24)
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
