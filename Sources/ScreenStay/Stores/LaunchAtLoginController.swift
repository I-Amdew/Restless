import Foundation

final class LaunchAtLoginController {
    private let label = "com.andrewturner.Restless"
    private let oldLabel = "com.andrewturner.ScreenStay"

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        try FileManager.default.createDirectory(
            at: launchAgentsURL,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                appLaunchPath
            ],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        _ = runLaunchctl(arguments: ["bootout", userDomain, oldPlistURL.path])
        try? FileManager.default.removeItem(at: oldPlistURL)
        _ = runLaunchctl(arguments: ["bootout", userDomain, plistURL.path])

        let bootstrapResult = runLaunchctl(arguments: ["bootstrap", userDomain, plistURL.path])
        if case .failure(let error) = bootstrapResult {
            throw error
        }
    }

    private func uninstall() throws {
        _ = runLaunchctl(arguments: ["bootout", userDomain, plistURL.path])
        try? FileManager.default.removeItem(at: oldPlistURL)

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private var appLaunchPath: String {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.path
        }

        return Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    private var launchAgentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsURL.appendingPathComponent("\(label).plist")
    }

    private var oldPlistURL: URL {
        launchAgentsURL.appendingPathComponent("\(oldLabel).plist")
    }

    private var userDomain: String {
        "gui/\(getuid())"
    }

    private func runLaunchctl(arguments: [String]) -> Result<Void, Error> {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
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

        return .failure(RestlessError.commandFailed(message ?? "Restless could not update launch at login."))
    }
}
