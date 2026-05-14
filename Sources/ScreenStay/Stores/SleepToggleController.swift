import Foundation

final class SleepToggleController {
    private(set) var isEnabled = false
    private(set) var isStatusKnown = false
    private(set) var batteryPercent: Int?
    private(set) var powerSource = "Unknown"
    private(set) var isLidClosed = false

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
        let ioregOutput = runPlainCommand("/usr/sbin/ioreg", arguments: ["-r", "-k", "SleepDisabled", "-d", "1"])

        if ioregOutput.contains(#""SleepDisabled" = Yes"#) {
            applySleepState(isEnabled: true, isKnown: true)
            return
        }

        if ioregOutput.contains(#""SleepDisabled" = No"#) {
            if isPausedForClosedLidSleep, rememberedEnabled {
                isEnabled = true
                isStatusKnown = true
                return
            }

            applySleepState(isEnabled: false, isKnown: true)
            return
        }

        let pmsetOutput = runPlainCommand("/usr/bin/pmset", arguments: ["-g", "custom"])
        if let parsedEnabled = parseDisableSleepState(from: pmsetOutput) {
            if !parsedEnabled, isPausedForClosedLidSleep, rememberedEnabled {
                isEnabled = true
                isStatusKnown = true
                return
            }

            applySleepState(isEnabled: parsedEnabled, isKnown: true)
            return
        }

        applySleepState(isEnabled: rememberedEnabled, isKnown: false)
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
            let result = Self.runPasswordlessPMSet(value: value)
                .orElse { Self.runAuthorizedAppleScript(appleScript) }

            DispatchQueue.main.async {
                switch result {
                case .success:
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
            let result = Self.runPasswordlessPMSet(value: "0")
                .orElse { Self.runAuthorizedAppleScript(appleScript) }

            DispatchQueue.main.async {
                switch result {
                case .success:
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

private extension Result where Failure == Error {
    func orElse(_ fallback: () -> Result<Success, Error>) -> Result<Success, Error> {
        switch self {
        case .success:
            return self
        case .failure:
            return fallback()
        }
    }
}
