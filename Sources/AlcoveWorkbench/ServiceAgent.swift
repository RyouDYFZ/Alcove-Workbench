import Foundation

/// Keeps the loopback license service alive for the whole login session.
/// Alcove refreshes its token whenever the License page opens; if the service is
/// unreachable at that moment the client drops its stored activation.
enum ServiceAgent {
    static let label = "ryo.AlcoveWorkbench.serve"
    static let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    static func install(executable: URL) throws {
        try Paths.prepareDirectories()
        let logPath = Paths.logDirectory.appendingPathComponent("serve.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--serve"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistPath)
        let domain = "gui/\(getuid())"
        _ = try? Command.run("/bin/launchctl", ["bootout", domain, plistPath.path], allowFailure: true)
        try Command.run("/bin/launchctl", ["bootstrap", domain, plistPath.path])
    }

    static func remove() throws {
        let domain = "gui/\(getuid())"
        _ = try? Command.run("/bin/launchctl", ["bootout", domain, plistPath.path], allowFailure: true)
        try? FileManager.default.removeItem(at: plistPath)
    }

    static func health() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(LocalActivationServer.port)/health") else {
            return false
        }
        var healthy = false
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            healthy = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        return healthy
    }
}
