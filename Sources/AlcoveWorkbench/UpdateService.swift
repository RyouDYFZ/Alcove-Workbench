import Foundation

struct DownloadedUpdate {
    let displayVersion: String
    let buildNumber: Int
    let appURL: URL
    let mountPoint: URL
    let workDirectory: URL

    func cleanUp() {
        _ = try? Command.run(
            "/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"],
            allowFailure: true
        )
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

enum UpdateService {
    /// The vendor's own update API requires a vendor-signed license token, but the
    /// public installer is the same artifact the app would download.
    static let dmgURL = URL(string: "https://download.tryalcove.com/Alcove.dmg")!

    static func fetchLatest() async throws -> DownloadedUpdate {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlcoveUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Alcove.dmg")
        do {
            try await download(dmgURL, to: dmg)
            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try Command.run("/usr/bin/hdiutil", [
                "attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path, "-quiet",
            ])
            let app = mount.appendingPathComponent("Alcove.app")
            guard AppBundle.isAlcove(app), let version = AppBundle.version(at: app) else {
                _ = try? Command.run(
                    "/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"],
                    allowFailure: true
                )
                throw WorkbenchError.message("官方安装包内没有找到 Alcove.app")
            }
            let buildText = version.split(separator: "(").last
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ") ")) } ?? ""
            return DownloadedUpdate(
                displayVersion: version,
                buildNumber: Int(buildText) ?? 0,
                appURL: app,
                mountPoint: mount,
                workDirectory: work
            )
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                if let error {
                    continuation.resume(throwing: WorkbenchError.message("下载失败：\(error.localizedDescription)"))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: WorkbenchError.message("下载失败：没有响应"))
                    return
                }
                guard response.statusCode == 200 else {
                    continuation.resume(throwing: WorkbenchError.message("下载失败：HTTP \(response.statusCode)"))
                    return
                }
                guard let temporary else {
                    continuation.resume(throwing: WorkbenchError.message("下载失败：临时文件缺失"))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: WorkbenchError.message("保存安装包失败：\(error.localizedDescription)"))
                }
            }
            task.resume()
        }
    }
}
