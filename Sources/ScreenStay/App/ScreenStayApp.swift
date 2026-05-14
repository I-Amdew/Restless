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

    @objc private func toggleFromMenu(_ sender: Any) {
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
        guard let minutes = promptForCustomValue(
            title: "Close Timer",
            symbolName: "timer",
            label: "Stay awake after lid closes",
            defaultValue: max(toggleController.sessionLimitMinutes, 30),
            minimum: 1,
            maximum: 720,
            step: 5,
            unit: "min"
        ) else { return }

        toggleController.sessionLimitMinutes = minutes
        handleSettingsChange()
    }

    @objc private func chooseCustomBatteryFloor(_ sender: NSMenuItem) {
        guard let percent = promptForCustomValue(
            title: "Battery Cutoff",
            symbolName: "battery.50",
            label: "Sleep closed at or below",
            defaultValue: max(toggleController.batteryFloorPercent, 40),
            minimum: 1,
            maximum: 99,
            step: 1,
            unit: "%"
        ) else { return }

        toggleController.batteryFloorPercent = percent
        handleSettingsChange()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any) {
        do {
            try launchAtLoginController.setEnabled(!launchAtLoginController.isEnabled)
            (sender as? CheckmarkMenuItemView)?.isChecked = launchAtLoginController.isEnabled
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

        let pillColor = statusPillColor
        statusItem?.length = NSStatusItem.squareLength

        button.wantsLayer = true
        button.layer?.cornerRadius = pillColor == nil ? 0 : NSStatusBar.system.thickness / 2
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = pillColor?.cgColor
        button.image = statusItemImage(tintColor: pillColor == nil ? nil : .white)
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = nil
        button.alphaValue = 1.0
        button.toolTip = statusToolTip
    }

    private func statusItemImage(tintColor: NSColor?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: "Restless")?
            .withSymbolConfiguration(configuration)

        guard let tintColor else {
            image?.isTemplate = true
            return image
        }

        let tintedImage = image?.withSymbolConfiguration(.init(hierarchicalColor: tintColor)) ?? image
        tintedImage?.isTemplate = false
        return tintedImage
    }

    private var statusPillColor: NSColor? {
        if toggleController.shouldUseWarningIcon {
            return .systemOrange
        }

        if toggleController.isEnabled {
            return .systemBlue
        }

        return nil
    }

    private var statusToolTip: String {
        guard toggleController.isStatusKnown else {
            return "Restless: checking sleep status"
        }

        if isPausedByBatteryCutoff {
            return "Restless paused: battery is at or below the \(batteryLimitTitle()) cutoff."
        }

        if isPausedAfterClosedLidLimit {
            return "Restless paused: closed-lid limit reached. It will re-arm when the lid opens."
        }

        return toggleController.isEnabled ? "Restless on: sleep disabled" : "Restless off: normal sleep"
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

    private func headerMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = HeaderMenuItemView(
            title: "Restless",
            detail: headerSubtitle,
            isEnabled: toggleController.isEnabled,
            target: self,
            action: #selector(toggleFromMenu(_:))
        )
        return item
    }

    private var headerSubtitle: String {
        if !toggleController.isStatusKnown {
            return "Checking sleep status"
        }

        if isPausedByBatteryCutoff {
            return "Paused: battery below \(batteryLimitTitle())"
        }

        if isPausedAfterClosedLidLimit {
            return "Paused until lid opens"
        }

        return toggleController.isEnabled ? "Closed-lid keep-awake is on" : "Normal sleep"
    }

    private func sectionHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SectionHeaderView(title: title)
        return item
    }

    private func statusSummaryItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = StatusRowView(
            symbolName: "display",
            accentColor: statusAccentColor,
            title: statusTitle,
            subtitle: statusDetail,
            trailing: toggleController.batteryPercent.map { "\($0)%" }
        )
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
        guard toggleController.isStatusKnown else {
            return "Checking status"
        }

        if isPausedByBatteryCutoff {
            return "Battery too low"
        }

        if isPausedAfterClosedLidLimit {
            return "Close limit reached"
        }

        return toggleController.isEnabled ? "Sleep prevented" : "Normal sleep"
    }

    private var statusDetail: String {
        if isPausedByBatteryCutoff {
            return "At/below \(batteryLimitTitle()); keep-awake paused"
        }

        if isPausedAfterClosedLidLimit {
            return "Will re-arm when the lid opens"
        }

        return toggleController.closedSessionMetricsTitle ?? "No closed session yet"
    }

    private var statusAccentColor: NSColor {
        if toggleController.shouldUseWarningIcon {
            return .systemOrange
        }

        return toggleController.isEnabled ? .systemBlue : .tertiaryLabelColor
    }

    private var isPausedByBatteryCutoff: Bool {
        toggleController.isEnabled && toggleController.isBatteryCutoffReached
    }

    private var isPausedAfterClosedLidLimit: Bool {
        toggleController.isEnabled && toggleController.isWaitingForNextLidOpen
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
        item.view = CheckmarkMenuItemView(
            title: "Start at Login",
            isChecked: launchAtLoginController.isEnabled,
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

        let customTitle = [0, 15, 30, 60].contains(toggleController.sessionLimitMinutes)
            ? "Custom..."
            : "Custom: \(timeLimitTitle())..."
        let customItem = NSMenuItem(title: customTitle, action: #selector(chooseCustomSessionLimit(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = [0, 15, 30, 60].contains(toggleController.sessionLimitMinutes) ? .off : .on
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

        for option in [0, 20, 40] {
            let title = option == 0 ? "Off" : "\(option)%"
            let menuItem = NSMenuItem(title: title, action: #selector(chooseBatteryFloor(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = option
            menuItem.state = toggleController.batteryFloorPercent == option ? .on : .off
            submenu.addItem(menuItem)
        }

        let customTitle = [0, 20, 40].contains(toggleController.batteryFloorPercent)
            ? "Custom..."
            : "Custom: \(batteryLimitTitle())..."
        let customItem = NSMenuItem(title: customTitle, action: #selector(chooseCustomBatteryFloor(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.state = [0, 20, 40].contains(toggleController.batteryFloorPercent) ? .off : .on
        submenu.addItem(customItem)

        return submenu.items
    }

    private func promptForCustomValue(
        title: String,
        symbolName: String,
        label: String,
        defaultValue: Int,
        minimum: Int,
        maximum: Int,
        step: Int,
        unit: String
    ) -> Int? {
        NSApp.activate(ignoringOtherApps: true)

        let accessory = CustomValueAccessoryView(
            label: label,
            value: defaultValue,
            minimum: minimum,
            maximum: maximum,
            step: step,
            unit: unit
        )

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Enter a custom value."
        alert.icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        accessory.focus()

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        guard let value = accessory.validatedValue else {
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

private final class CustomValueAccessoryView: NSView, NSTextFieldDelegate {
    private let valueField = NSTextField()
    private let stepper = NSStepper()
    private let minimum: Int
    private let maximum: Int

    var validatedValue: Int? {
        let value = valueField.integerValue
        guard value >= minimum, value <= maximum else { return nil }
        return value
    }

    init(label: String, value: Int, minimum: Int, maximum: Int, step: Int, unit: String) {
        self.minimum = minimum
        self.maximum = maximum
        super.init(frame: NSRect(x: 0, y: 0, width: 276, height: 78))

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 0, y: 56, width: 276, height: 16)
        addSubview(titleLabel)

        valueField.frame = NSRect(x: 0, y: 24, width: 86, height: 26)
        valueField.alignment = .right
        valueField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        valueField.integerValue = min(max(value, minimum), maximum)
        valueField.delegate = self
        addSubview(valueField)

        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = .systemFont(ofSize: 13, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.frame = NSRect(x: 94, y: 28, width: 56, height: 18)
        addSubview(unitLabel)

        stepper.frame = NSRect(x: 238, y: 22, width: 20, height: 28)
        stepper.minValue = Double(minimum)
        stepper.maxValue = Double(maximum)
        stepper.increment = Double(step)
        stepper.integerValue = valueField.integerValue
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        addSubview(stepper)

        let rangeLabel = NSTextField(labelWithString: "\(minimum)-\(maximum) \(unit)")
        rangeLabel.font = .systemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.frame = NSRect(x: 0, y: 1, width: 276, height: 14)
        addSubview(rangeLabel)
    }

    func focus() {
        window?.makeFirstResponder(valueField)
        valueField.selectText(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        let clamped = min(max(valueField.integerValue, minimum), maximum)
        stepper.integerValue = clamped
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        valueField.integerValue = sender.integerValue
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class HeaderMenuItemView: NSView {
    init(title: String, detail: String, isEnabled: Bool, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 58))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 18, y: 30, width: 168, height: 20)
        addSubview(titleLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 18, y: 12, width: 188, height: 16)
        addSubview(detailLabel)

        let toggle = MenuSwitchControl(frame: NSRect(x: 224, y: 16, width: 52, height: 32))
        toggle.isOn = isEnabled
        toggle.target = target
        toggle.action = action
        addSubview(toggle)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class MenuSwitchControl: NSControl {
    var isOn = false {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackRect = bounds.insetBy(dx: 2, dy: 4)
        let trackPath = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackRect.height / 2,
            yRadius: trackRect.height / 2
        )

        (isOn ? NSColor.systemBlue : NSColor.controlColor).setFill()
        trackPath.fill()

        if !isOn {
            NSColor.separatorColor.setStroke()
            trackPath.lineWidth = 0.5
            trackPath.stroke()
        }

        let knobDiameter = trackRect.height - 4
        let knobX = isOn ? trackRect.maxX - knobDiameter - 2 : trackRect.minX + 2
        let knobRect = NSRect(
            x: knobX,
            y: trackRect.minY + 2,
            width: knobDiameter,
            height: knobDiameter
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        sendAction(action, to: target)
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
    init(symbolName: String, accentColor: NSColor, title: String, subtitle: String, trailing: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 50))

        let iconBackground = NSView(frame: NSRect(x: 18, y: 8, width: 34, height: 34))
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 17
        iconBackground.layer?.backgroundColor = accentColor.withAlphaComponent(0.18).cgColor
        addSubview(iconBackground)

        let icon = NSImageView(frame: NSRect(x: 25, y: 15, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.contentTintColor = accentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(icon)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 64, y: 25, width: trailing == nil ? 210 : 152, height: 18)
        addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 64, y: 8, width: 210, height: 15)
        addSubview(subtitleLabel)

        if let trailing {
            let trailingLabel = NSTextField(labelWithString: trailing)
            trailingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            trailingLabel.textColor = .secondaryLabelColor
            trailingLabel.alignment = .right
            trailingLabel.frame = NSRect(x: 210, y: 25, width: 64, height: 18)
            addSubview(trailingLabel)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class CheckmarkMenuItemView: NSControl {
    private let checkmarkView = NSImageView()

    var isChecked: Bool {
        didSet {
            checkmarkView.isHidden = !isChecked
        }
    }

    init(title: String, isChecked: Bool, target: AnyObject, action: Selector) {
        self.isChecked = isChecked
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 32))

        self.target = target
        self.action = action

        checkmarkView.frame = NSRect(x: 20, y: 7, width: 18, height: 18)
        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: title)
        checkmarkView.contentTintColor = .labelColor
        checkmarkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        checkmarkView.isHidden = !isChecked
        addSubview(checkmarkView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 44, y: 7, width: 230, height: 18)
        addSubview(titleLabel)
    }

    override func mouseDown(with event: NSEvent) {
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

        let messageLabel = NSTextField(labelWithString: "Stop asking for your password.")
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
