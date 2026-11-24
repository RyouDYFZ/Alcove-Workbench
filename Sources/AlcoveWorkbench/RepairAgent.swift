import Foundation

enum RepairAgent {
    static let label = "ryo.AlcoveWorkbench.repair"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.launchAgent.path)
    }

    static func install(executable: URL, destinationApp: String) throws {
        try Paths.prepareDirectories()
        let logPath = Paths.logDirectory.appendingPathComponent("repair.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--repair"],
            "WatchPaths": [destinationApp],
            "RunAtLoad": true,
            "ThrottleInterval": 20,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: Paths.launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: Paths.launchAgent)
        let domain = "gui/\(getuid())"
        _ = try? Command.run("/bin/launchctl", ["bootout", domain, Paths.launchAgent.path], allowFailure: true)
        try Command.run("/bin/launchctl", ["bootstrap", domain, Paths.launchAgent.path])
    }

    static func remove() throws {
        let domain = "gui/\(getuid())"
        _ = try? Command.run("/bin/launchctl", ["bootout", domain, Paths.launchAgent.path], allowFailure: true)
        try? FileManager.default.removeItem(at: Paths.launchAgent)
    }
}
