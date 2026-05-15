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

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let passwordRow: SetupTaskRow
    private let launchRow: SetupTaskRow
    private let messageLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private var isLaunchAtLoginEnabled: Bool
    private var isPasswordlessInstalled: Bool
    private var isSetupRunning = false

    init(
        isLaunchAtLoginEnabled: Bool,
        isPasswordlessInstalled: Bool,
        setLaunchAtLogin: @escaping (Bool) -> OnboardingActionResult,
        runSetup: @escaping (@escaping (OnboardingSetupResult) -> Void) -> Void,
        finish: @escaping () -> Void
    ) {
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.isPasswordlessInstalled = isPasswordlessInstalled
        self.setLaunchAtLogin = setLaunchAtLogin
        self.runSetup = runSetup
        self.finish = finish

        passwordRow = SetupTaskRow(
            symbolName: "lock.open",
            title: "Allow keep-awake control",
            detail: "Enter your Mac password once.",
            actionTitle: "Allow",
            isComplete: isPasswordlessInstalled
        )
        launchRow = SetupTaskRow(
            symbolName: "arrow.clockwise",
            title: "Start at Login",
            detail: "Open Restless automatically.",
            actionTitle: "Enable",
            isComplete: isLaunchAtLoginEnabled
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 386),
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

        let iconBackground = NSView(frame: NSRect(x: 28, y: 302, width: 54, height: 54))
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 15
        iconBackground.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        root.addSubview(iconBackground)

        let iconView = NSImageView(frame: NSRect(x: 39, y: 313, width: 32, height: 32))
        iconView.image = Bundle.main.image(forResource: "Restless") ??
            NSImage(systemSymbolName: "display", accessibilityDescription: "Restless")
        iconView.contentTintColor = .systemBlue
        root.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 23, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 98, y: 328, width: 292, height: 28)
        root.addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.frame = NSRect(x: 98, y: 296, width: 292, height: 36)
        root.addSubview(detailLabel)

        let overview = SetupOverviewView(frame: NSRect(x: 28, y: 184, width: 374, height: 88))
        root.addSubview(overview)

        let separator = NSBox(frame: NSRect(x: 28, y: 164, width: 374, height: 1))
        separator.boxType = .separator
        root.addSubview(separator)

        passwordRow.frame.origin = NSPoint(x: 28, y: 100)
        passwordRow.target = self
        passwordRow.action = #selector(allowKeepAwakeControl(_:))
        root.addSubview(passwordRow)

        launchRow.frame.origin = NSPoint(x: 28, y: 48)
        launchRow.target = self
        launchRow.action = #selector(enableStartup(_:))
        root.addSubview(launchRow)

        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.frame = NSRect(x: 28, y: 18, width: 238, height: 16)
        root.addSubview(messageLabel)

        doneButton.target = self
        doneButton.action = #selector(doneAction)
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .large
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: 282, y: 14, width: 120, height: 30)
        root.addSubview(doneButton)
    }

    private func refresh() {
        passwordRow.isComplete = isPasswordlessInstalled
        launchRow.isComplete = isLaunchAtLoginEnabled

        let isComplete = isPasswordlessInstalled && isLaunchAtLoginEnabled
        titleLabel.stringValue = isComplete ? "Restless is Ready" : "Set Up Restless"
        detailLabel.stringValue = isComplete
            ? "Use the display icon in the menu bar to turn keep-awake on, set limits, and check status."
            : "A tiny menu bar app for keeping closed-lid work running, then sleeping at your limits."

        passwordRow.isActionEnabled = !isSetupRunning
        launchRow.isActionEnabled = !isSetupRunning
        doneButton.isEnabled = isComplete && !isSetupRunning

        if !isSetupRunning {
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.stringValue = ""
        }
    }

    @objc private func doneAction() {
        guard isPasswordlessInstalled && isLaunchAtLoginEnabled else { return }
        finish()
    }

    @objc private func allowKeepAwakeControl(_ sender: Any) {
        guard !isPasswordlessInstalled else { return }
        runPasswordSetup()
    }

    @objc private func enableStartup(_ sender: Any) {
        guard !isLaunchAtLoginEnabled else { return }
        enableLaunchAtLogin()
    }

    private func runPasswordSetup() {
        isSetupRunning = true
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "Waiting for macOS permission..."
        refresh()

        runSetup { [weak self] result in
            guard let self else { return }
            self.isSetupRunning = false

            switch result {
            case .success(let launchAtLoginEnabled, let passwordlessInstalled):
                self.isLaunchAtLoginEnabled = launchAtLoginEnabled
                self.isPasswordlessInstalled = passwordlessInstalled
                self.messageLabel.textColor = .secondaryLabelColor
                self.messageLabel.stringValue = "Permission enabled."
            case .failure(let message):
                self.messageLabel.textColor = .systemRed
                self.messageLabel.stringValue = message
            }

            self.refresh()
        }
    }

    private func enableLaunchAtLogin() {
        switch setLaunchAtLogin(true) {
        case .success:
            isLaunchAtLoginEnabled = true
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.stringValue = "Startup enabled."
        case .failure(let message):
            messageLabel.textColor = .systemRed
            messageLabel.stringValue = message
        }

        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class SetupOverviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addRow(symbolName: "display", text: "Keeps tasks running when the lid is closed.", y: 58)
        addRow(symbolName: "timer", text: "Stops at your timer or battery cutoff.", y: 29)
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

private final class SetupTaskRow: NSView {
    private let iconBackground = NSView(frame: NSRect(x: 0, y: 10, width: 34, height: 34))
    private let iconView = NSImageView(frame: NSRect(x: 8, y: 18, width: 18, height: 18))
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView(frame: NSRect(x: 350, y: 16, width: 22, height: 22))
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    weak var target: AnyObject?
    var action: Selector?

    var isActionEnabled = true {
        didSet {
            actionButton.isEnabled = isActionEnabled
        }
    }

    var isComplete: Bool {
        didSet {
            refresh()
        }
    }

    init(symbolName: String, title: String, detail: String, actionTitle: String, isComplete: Bool) {
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
        titleLabel.frame = NSRect(x: 48, y: 29, width: 226, height: 17)
        addSubview(titleLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 48, y: 10, width: 226, height: 15)
        addSubview(detailLabel)

        addSubview(checkView)

        actionButton.title = actionTitle
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11, weight: .semibold)
        actionButton.target = self
        actionButton.action = #selector(performRowAction)
        actionButton.frame = NSRect(x: 298, y: 14, width: 74, height: 26)
        addSubview(actionButton)

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
        checkView.isHidden = !isComplete
        actionButton.isHidden = isComplete
        actionButton.isEnabled = isActionEnabled
    }

    @objc private func performRowAction() {
        guard let target, let action else { return }
        _ = target.perform(action, with: self)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
