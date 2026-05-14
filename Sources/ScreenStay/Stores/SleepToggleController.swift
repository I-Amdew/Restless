import Foundation

final class SleepToggleController {
    private(set) var isEnabled = false
    private(set) var isStatusKnown = false
    private(set) var batteryPercent: Int?
    private(set) var powerSource = "Unknown"
    private(set) var isLidClosed = false
    private(set) var isPasswordlessSetupInstalled: Bool = UserDefaults.standard.bool(
        forKey: "restless.passwordlessSetupInstalled"
    )

    var closedSessionMetricsTitle: String? {
        guard isLidClosed, let closedSince else {
            return lastClosedSessionSummary
        }

        var parts = ["Current session: \(formatDuration(Date().timeIntervalSince(closedSince)))"]

        if let drain = closedSessionBatteryDrain {
            parts.append(drain == 0 ? "0% used" : "\(drain)% used")
        }

        return parts.joined(separator: " · ")
    }

    var sessionLimitMinutes: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: "restless.sessionLimitMinutes") as? Int
            return stored ?? 30
        }
        set {
            let clampedValue = max(0, newValue)
            UserDefaults.standard.set(clampedValue, forKey: "restless.sessionLimitMinutes")
            UserDefaults.standard.synchronize()
        }
    }

    var batteryFloorPercent: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: "restless.batteryFloorPercent") as? Int
            return stored ?? 40
        }
        set {
            let clampedValue = min(99, max(0, newValue))
            UserDefaults.standard.set(clampedValue, forKey: "restless.batteryFloorPercent")
            UserDefaults.standard.synchronize()
        }
    }

    var shouldStopForLimit: Bool {
        guard isEnabled, !isPausedForClosedLidSleep else { return false }

        if isLidClosed, isBatteryCutoffReached {
            return true
        }

        if shouldScheduleCloseLimitTimer, closedLimitRemainingSeconds <= 0 {
            return true
        }

        return false
    }

    var isBatteryCutoffReached: Bool {
        powerSource == "Battery"
            && batteryFloorPercent > 0
            && batteryPercent.map { $0 <= batteryFloorPercent } == true
    }

    var isWaitingForNextLidOpen: Bool {
        isPausedForClosedLidSleep && rememberedEnabled
    }

    var shouldUseWarningIcon: Bool {
        isEnabled && (isBatteryCutoffReached || isWaitingForNextLidOpen)
    }

    var shouldScheduleCloseLimitTimer: Bool {
        isEnabled && !isPausedForClosedLidSleep && isLidClosed && sessionLimitMinutes > 0 && closedSince != nil
    }

    var closedLimitRemainingSeconds: Int {
        guard shouldScheduleCloseLimitTimer, let closedSince else { return 0 }

        let total = TimeInterval(sessionLimitMinutes * 60)
        return max(0, Int(ceil(total - Date().timeIntervalSince(closedSince))))
    }

    var closedLimitRemainingText: String? {
        guard shouldScheduleCloseLimitTimer else { return nil }

        return "Time left: \(formatDuration(TimeInterval(closedLimitRemainingSeconds)))"
    }

    private var closedSince: Date? {
        didSet {
            if let closedSince {
                UserDefaults.standard.set(closedSince.timeIntervalSince1970, forKey: "restless.closedSince")
            } else {
                UserDefaults.standard.removeObject(forKey: "restless.closedSince")
            }
            UserDefaults.standard.synchronize()
        }
    }
    private var batteryAtClose: Int? {
        didSet {
            if let batteryAtClose {
                UserDefaults.standard.set(batteryAtClose, forKey: "restless.batteryAtClose")
            } else {
                UserDefaults.standard.removeObject(forKey: "restless.batteryAtClose")
            }
            UserDefaults.standard.synchronize()
        }
    }
    private var lastClosedSessionSummary: String? {
        get { UserDefaults.standard.string(forKey: "restless.lastClosedSessionSummary") }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "restless.lastClosedSessionSummary")
            } else {
                UserDefaults.standard.removeObject(forKey: "restless.lastClosedSessionSummary")
            }
            UserDefaults.standard.synchronize()
        }
    }
    private var closedSessionBatteryDrain: Int? {
        guard let batteryAtClose, let batteryPercent else { return nil }
        return max(0, batteryAtClose - batteryPercent)
    }
    private var rememberedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "restless.desiredEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "restless.desiredEnabled")
            UserDefaults.standard.synchronize()
        }
    }
    private var isPausedForClosedLidSleep: Bool {
        get { UserDefaults.standard.bool(forKey: "restless.pausedForClosedLidSleep") }
        set {
            UserDefaults.standard.set(newValue, forKey: "restless.pausedForClosedLidSleep")
            UserDefaults.standard.synchronize()
        }
    }

    init() {
        let storedClosedSince = UserDefaults.standard.double(forKey: "restless.closedSince")
        if storedClosedSince > 0 {
            closedSince = Date(timeIntervalSince1970: storedClosedSince)
        }

        let storedBatteryAtClose = UserDefaults.standard.object(forKey: "restless.batteryAtClose") as? Int
        batteryAtClose = storedBatteryAtClose
    }

    func refresh() {
        if let actualSleepDisabled = readActualSleepDisabled() {
            if !actualSleepDisabled, isPausedForClosedLidSleep, rememberedEnabled {
                isEnabled = true
                isStatusKnown = true
                return
            }

            applySleepState(isEnabled: actualSleepDisabled, isKnown: true)
            return
        }

        applySleepState(isEnabled: rememberedEnabled, isKnown: false)
    }

    func refreshPasswordlessSetupStatus() {
        guard !isPasswordlessSetupInstalled, let actualSleepDisabled = readActualSleepDisabled() else {
            return
        }

        if case .success = Self.runPasswordlessPMSet(value: actualSleepDisabled ? "1" : "0") {
            markPasswordlessSetupInstalled()
        }
    }

    func monitor() {
        refresh()
        refreshBattery()

        let wasClosed = isLidClosed
        isLidClosed = readLidClosed()

        if isPausedForClosedLidSleep {
            return
        }

        guard isEnabled else {
            finishClosedSessionIfNeeded()
            closedSince = nil
            batteryAtClose = nil
            return
        }

        if isLidClosed {
            if closedSince == nil {
                startClosedSession()
            }

            if !wasClosed {
                forceDisplaySleep()
            }
        } else {
            finishClosedSessionIfNeeded()
            closedSince = nil
            batteryAtClose = nil
        }
    }

    func setSleepDisabled(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let value = enabled ? "1" : "0"
        let shellCommand = "/usr/bin/pmset -a disablesleep \(value)"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let passwordlessResult = Self.runPasswordlessPMSet(value: value)
            let usedPasswordless: Bool
            let result: Result<Void, Error>

            switch passwordlessResult {
            case .success:
                usedPasswordless = true
                result = passwordlessResult
            case .failure:
                usedPasswordless = false
                result = Self.runAuthorizedAppleScript(appleScript)
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    if usedPasswordless {
                        self.markPasswordlessSetupInstalled()
                    }
                    self.isPausedForClosedLidSleep = false
                    self.applySleepState(isEnabled: enabled, isKnown: true)
                    if !enabled {
                        self.finishClosedSessionIfNeeded()
                        self.closedSince = nil
                        self.batteryAtClose = nil
                    }
                    completion(.success(()))
                case .failure(let error):
                    self.refresh()
                    completion(.failure(error))
                }
            }
        }
    }

    func pauseForClosedLidLimit(completion: @escaping (Result<Void, Error>) -> Void) {
        let shellCommand = "/usr/bin/pmset -a disablesleep 0"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let passwordlessResult = Self.runPasswordlessPMSet(value: "0")
            let usedPasswordless: Bool
            let result: Result<Void, Error>

            switch passwordlessResult {
            case .success:
                usedPasswordless = true
                result = passwordlessResult
            case .failure:
                usedPasswordless = false
                result = Self.runAuthorizedAppleScript(appleScript)
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    if usedPasswordless {
                        self.markPasswordlessSetupInstalled()
                    }
                    self.finishClosedSessionIfNeeded()
                    self.closedSince = nil
                    self.batteryAtClose = nil
                    self.isPausedForClosedLidSleep = true
                    self.isEnabled = true
                    self.isStatusKnown = true
                    self.rememberedEnabled = true
                    completion(.success(()))
                case .failure(let error):
                    self.refresh()
                    completion(.failure(error))
                }
            }
        }
    }

    func installPasswordlessToggle(completion: @escaping (Result<Void, Error>) -> Void) {
        let userName = NSUserName()
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard userName.rangeOfCharacter(from: allowedCharacters.inverted) == nil else {
            completion(.failure(RestlessError.commandFailed("Restless could not install setup for this macOS user name.")))
            return
        }

        let rule = "\(userName) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let encodedRule = Data(rule.utf8).base64EncodedString()
        let adminCommand = [
            "/bin/mkdir -p /etc/sudoers.d",
            "/bin/echo '\(encodedRule)' | /usr/bin/base64 -D > /tmp/restless-pmset-sudoers",
            "/usr/sbin/visudo -cf /tmp/restless-pmset-sudoers",
            "/usr/bin/install -m 0440 /tmp/restless-pmset-sudoers /etc/sudoers.d/restless-pmset",
            "/bin/rm -f /tmp/restless-pmset-sudoers"
        ].joined(separator: " && ")
        let appleScript = "do shell script \"\(Self.escapeForAppleScript(adminCommand))\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runAuthorizedAppleScript(appleScript)

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.markPasswordlessSetupInstalled()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func requestSystemSleep() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.runPlainCommand("/usr/bin/pmset", arguments: ["sleepnow"])
        }
    }

    var shouldResumeAfterClosedLidSleep: Bool {
        isPausedForClosedLidSleep && rememberedEnabled && !isLidClosed
    }

    func markResumingAfterClosedLidSleep() {
        isPausedForClosedLidSleep = false
    }

    private func markPasswordlessSetupInstalled() {
        isPasswordlessSetupInstalled = true
        UserDefaults.standard.set(true, forKey: "restless.passwordlessSetupInstalled")
        UserDefaults.standard.synchronize()
    }

    private func startClosedSession() {
        closedSince = Date()
        batteryAtClose = batteryPercent
        lastClosedSessionSummary = nil
    }

    private func applySleepState(isEnabled: Bool, isKnown: Bool) {
        self.isEnabled = isEnabled
        isStatusKnown = isKnown
        isPausedForClosedLidSleep = false
        rememberedEnabled = isEnabled
    }

    private func parseDisableSleepState(from output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "disablesleep" else { continue }

            if parts[1] == "1" {
                return true
            }

            if parts[1] == "0" {
                return false
            }
        }

        return nil
    }

    private func readActualSleepDisabled() -> Bool? {
        let ioregOutput = runPlainCommand("/usr/sbin/ioreg", arguments: ["-r", "-k", "SleepDisabled", "-d", "1"])

        if ioregOutput.contains(#""SleepDisabled" = Yes"#) {
            return true
        }

        if ioregOutput.contains(#""SleepDisabled" = No"#) {
            return false
        }

        let pmsetOutput = runPlainCommand("/usr/bin/pmset", arguments: ["-g", "custom"])
        return parseDisableSleepState(from: pmsetOutput)
    }

    private func refreshBattery() {
        let output = runPlainCommand("/usr/bin/pmset", arguments: ["-g", "batt"])

        if let percentRange = output.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentText = output[percentRange].dropLast()
            batteryPercent = Int(percentText)
        } else {
            batteryPercent = nil
        }

        if output.contains("Battery Power") {
            powerSource = "Battery"
        } else if output.contains("AC Power") {
            powerSource = "Power Adapter"
        } else {
            powerSource = "Unknown"
        }
    }

    private func readLidClosed() -> Bool {
        let output = runPlainCommand("/usr/sbin/ioreg", arguments: ["-r", "-k", "AppleClamshellState", "-d", "4"])
        return output.contains(#""AppleClamshellState" = Yes"#)
    }

    private func forceDisplaySleep() {
        _ = runPlainCommand("/usr/bin/pmset", arguments: ["displaysleepnow"])
    }

    private func finishClosedSessionIfNeeded() {
        guard let closedSince else { return }

        var parts = ["Last session: \(formatDuration(Date().timeIntervalSince(closedSince)))"]

        if let drain = closedSessionBatteryDrain {
            parts.append(drain == 0 ? "0% used" : "\(drain)% used")
        }

        lastClosedSessionSummary = parts.joined(separator: " · ")
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))

        if totalMinutes < 60 {
            return "\(max(1, totalMinutes)) min"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    private static func runPasswordlessPMSet(value: String) -> Result<Void, Error> {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error)
        }

        if process.terminationStatus == 0 {
            return .success(())
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return .failure(RestlessError.commandFailed(message ?? "Passwordless pmset is not configured."))
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runPlainCommand(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func runAuthorizedAppleScript(_ source: String) -> Result<Void, Error> {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error)
        }

        if process.terminationStatus == 0 {
            return .success(())
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return .failure(RestlessError.commandFailed(message ?? "The admin command was cancelled or failed."))
    }
}

enum RestlessError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}
