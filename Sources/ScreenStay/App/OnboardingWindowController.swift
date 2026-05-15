import AppKit

enum OnboardingSetupResult {
    case success(launchAtLoginEnabled: Bool, passwordlessInstalled: Bool)
    case failure(String)
}

enum OnboardingActionResult {
    case success
    case failure(String)
}

final class OnboardingWindowController: NSWindowController {
    private let setLaunchAtLogin: (Bool) -> OnboardingActionResult
    private let runSetup: (@escaping (OnboardingSetupResult) -> Void) -> Void
    private let finish: () -> Void

    private let titleLabel = NSTextField(labelWithString: "Set Up Restless")
    private let detailLabel = NSTextField(labelWithString: "")
    private let installNotice = NSTextField(labelWithString: "")
    private let passwordRow: SetupChecklistRow
    private let launchRow: SetupToggleRow
    private let errorLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "Allow", target: nil, action: nil)

    private var isInstalledInApplications: Bool
    private var isLaunchAtLoginEnabled: Bool
    private var isPasswordlessInstalled: Bool
    private var isSetupRunning = false

    init(
        isInstalledInApplications: Bool,
        isLaunchAtLoginEnabled: Bool,
        isPasswordlessInstalled: Bool,
        setLaunchAtLogin: @escaping (Bool) -> OnboardingActionResult,
        runSetup: @escaping (@escaping (OnboardingSetupResult) -> Void) -> Void,
        finish: @escaping () -> Void
    ) {
        self.isInstalledInApplications = isInstalledInApplications
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.isPasswordlessInstalled = isPasswordlessInstalled
        self.setLaunchAtLogin = setLaunchAtLogin
        self.runSetup = runSetup
        self.finish = finish

        passwordRow = SetupChecklistRow(
            symbolName: "lock.open",
            title: "Allow keep-awake control",
            detail: "Enter your Mac password once.",
            isComplete: isPasswordlessInstalled
        )
        launchRow = SetupToggleRow(
            symbolName: "arrow.clockwise",
            title: "Start at Login",
            detail: "Open Restless automatically.",
            isOn: isLaunchAtLoginEnabled
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 392),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Restless Setup"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        buildContent()
        refresh()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let window else { return }

        let root = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        window.contentView = root

        let iconBackground = NSView(frame: NSRect(x: 28, y: 308, width: 54, height: 54))
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 15
        iconBackground.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        root.addSubview(iconBackground)

        let iconView = NSImageView(frame: NSRect(x: 39, y: 319, width: 32, height: 32))
        iconView.image = Bundle.main.image(forResource: "Restless") ??
            NSImage(systemSymbolName: "display", accessibilityDescription: "Restless")
        iconView.contentTintColor = .systemBlue
        root.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 23, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 98, y: 335, width: 292, height: 28)
        root.addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.frame = NSRect(x: 98, y: 298, width: 292, height: 42)
        root.addSubview(detailLabel)

        let overview = SetupOverviewView(frame: NSRect(x: 28, y: 180, width: 374, height: 94))
        root.addSubview(overview)

        let separator = NSBox(frame: NSRect(x: 28, y: 162, width: 374, height: 1))
        separator.boxType = .separator
        root.addSubview(separator)

        installNotice.font = .systemFont(ofSize: 12, weight: .regular)
        installNotice.textColor = .systemRed
        installNotice.lineBreakMode = .byWordWrapping
        installNotice.frame = NSRect(x: 28, y: 120, width: 374, height: 34)
        root.addSubview(installNotice)

        passwordRow.frame.origin = NSPoint(x: 28, y: 92)
        root.addSubview(passwordRow)

        launchRow.frame.origin = NSPoint(x: 28, y: 38)
        launchRow.target = self
        launchRow.action = #selector(toggleLaunchAtLogin(_:))
        root.addSubview(launchRow)

        errorLabel.font = .systemFont(ofSize: 12, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.frame = NSRect(x: 28, y: 48, width: 244, height: 16)
        root.addSubview(errorLabel)

        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"
        primaryButton.frame = NSRect(x: 282, y: 14, width: 120, height: 30)
        root.addSubview(primaryButton)
    }

    private func refresh() {
        passwordRow.isComplete = isPasswordlessInstalled
        launchRow.isOn = isLaunchAtLoginEnabled

        titleLabel.stringValue = isPasswordlessInstalled ? "Restless is Ready" : "Set Up Restless"
        detailLabel.stringValue = isPasswordlessInstalled
            ? "Use the display icon in the menu bar to turn keep-awake on, set limits, and check status."
            : "Restless needs one password prompt so it can toggle closed-lid keep-awake later."

        installNotice.isHidden = isInstalledInApplications
        installNotice.stringValue = "Move Restless.app to Applications from the DMG, then open it there to finish setup."
        passwordRow.isHidden = !isInstalledInApplications || isPasswordlessInstalled
        launchRow.isHidden = !isInstalledInApplications

        if isInstalledInApplications && !isPasswordlessInstalled {
            passwordRow.frame.origin = NSPoint(x: 28, y: 84)
            launchRow.frame.origin = NSPoint(x: 28, y: 30)
        } else if isInstalledInApplications {
            launchRow.frame.origin = NSPoint(x: 28, y: 84)
        }

        primaryButton.title = isPasswordlessInstalled ? "Done" : "Allow"
        primaryButton.isEnabled = !isSetupRunning && isInstalledInApplications
        errorLabel.stringValue = isSetupRunning || !isInstalledInApplications ? errorLabel.stringValue : ""
    }

    @objc private func toggleLaunchAtLogin(_ sender: SetupToggleRow) {
        let previousValue = isLaunchAtLoginEnabled
        let requestedValue = sender.isOn

        switch setLaunchAtLogin(requestedValue) {
        case .success:
            isLaunchAtLoginEnabled = requestedValue
            errorLabel.stringValue = ""
        case .failure(let message):
            isLaunchAtLoginEnabled = previousValue
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = message
        }

        refresh()
    }

    @objc private func primaryAction() {
        if isPasswordlessInstalled {
            finish()
            return
        }

        isSetupRunning = true
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.stringValue = "Waiting for macOS permission..."
        primaryButton.isEnabled = false

        runSetup { [weak self] result in
            guard let self else { return }
            self.isSetupRunning = false

            switch result {
            case .success(let launchAtLoginEnabled, let passwordlessInstalled):
                self.isLaunchAtLoginEnabled = launchAtLoginEnabled
                self.isPasswordlessInstalled = passwordlessInstalled
                self.errorLabel.textColor = .secondaryLabelColor
                self.errorLabel.stringValue = "Setup complete."
            case .failure(let message):
                self.errorLabel.textColor = .systemRed
                self.errorLabel.stringValue = message
            }

            self.refresh()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class SetupOverviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addRow(symbolName: "display", text: "Keeps tasks running when the lid is closed.", y: 64)
        addRow(symbolName: "timer", text: "Stops at your timer or battery cutoff.", y: 32)
        addRow(symbolName: "menubar.rectangle", text: "Lives in the menu bar after setup.", y: 0)
    }

    private func addRow(symbolName: String, text: String, y: CGFloat) {
        let icon = NSImageView(frame: NSRect(x: 0, y: y + 3, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .systemBlue
        addSubview(icon)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 30, y: y, width: 344, height: 22)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class SetupChecklistRow: NSView {
    private let iconBackground = NSView(frame: NSRect(x: 0, y: 10, width: 34, height: 34))
    private let iconView = NSImageView(frame: NSRect(x: 8, y: 18, width: 18, height: 18))
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView(frame: NSRect(x: 350, y: 16, width: 22, height: 22))

    var isComplete: Bool {
        didSet {
            refresh()
        }
    }

    init(symbolName: String, title: String, detail: String, isComplete: Bool) {
        self.isComplete = isComplete
        super.init(frame: NSRect(x: 0, y: 0, width: 374, height: 54))

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 17
        addSubview(iconBackground)

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 48, y: 29, width: 288, height: 17)
        addSubview(titleLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 48, y: 10, width: 288, height: 15)
        addSubview(detailLabel)

        addSubview(checkView)
        refresh()
    }

    private func refresh() {
        let color: NSColor = isComplete ? .systemGreen : .systemBlue
        iconBackground.layer?.backgroundColor = color.withAlphaComponent(isComplete ? 0.2 : 0.16).cgColor
        iconView.contentTintColor = color
        checkView.image = NSImage(
            systemSymbolName: isComplete ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: isComplete ? "Complete" : "Not complete"
        )
        checkView.contentTintColor = isComplete ? .systemGreen : .tertiaryLabelColor
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class SetupToggleRow: NSControl {
    private let iconBackground = NSView(frame: NSRect(x: 0, y: 10, width: 34, height: 34))
    private let iconView = NSImageView(frame: NSRect(x: 8, y: 18, width: 18, height: 18))
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch(frame: NSRect(x: 324, y: 13, width: 50, height: 28))

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    init(symbolName: String, title: String, detail: String, isOn: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 374, height: 54))

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 17
        iconBackground.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
        addSubview(iconBackground)

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.contentTintColor = .systemBlue
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 48, y: 29, width: 260, height: 17)
        addSubview(titleLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 48, y: 10, width: 260, height: 15)
        addSubview(detailLabel)

        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        addSubview(toggle)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        _ = target?.perform(action, with: self)
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        _ = target?.perform(action, with: self)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
