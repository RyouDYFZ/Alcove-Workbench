import Foundation

struct PatchSummary: Sendable {
    var publicKeyHits: Int
    var urlHits: Int
    var teamHits: Int
    var nestedBinaries: [String]
}

enum Patcher {
    static let vendorPublicKey = Data("/xVtq2IxbZ7dchEE3wP3auchoNOWzk2vnueLyY8C/h8=".utf8)
    static let vendorURL = Data("https://api.tryalcove.com".utf8)
    static let localURL = Data("http://127.0.0.1:8199/api".utf8)
    static let vendorTeam = Data("287NUTSP69".utf8)
    static let alcoveBundleID = "com.henrikruscon.Alcove"

    /// Copies the source bundle, rewrites the licensing anchors, and signs the copy.
    static func prepare(
        source: URL,
        destination: URL,
        key: ActivationKey,
        teamID: String,
        identity: String,
        profile: ProvisioningProfile?,
        log: (String) -> Void
    ) throws -> PatchSummary {
        guard AppBundle.isAlcove(source) else {
            throw WorkbenchError.message("源 App 不是有效的 macOS 应用：\(source.path)")
        }
        guard localURL.count == vendorURL.count else {
            throw WorkbenchError.message("本地 API 地址长度与生产地址不一致")
        }
        guard Data(key.publicKey.utf8).count == vendorPublicKey.count else {
            throw WorkbenchError.message("本地公钥编码长度不正确")
        }
        guard teamID.count == 10 else {
            throw WorkbenchError.message("签名 Team ID 必须是 10 个字符")
        }

        let fileManager = FileManager.default
        let inPlace = source.standardizedFileURL == destination.standardizedFileURL
        if inPlace {
            log("就地替换：\(destination.path)")
        } else {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            log("复制 \(source.lastPathComponent) → \(destination.path)")
            try Command.run("/usr/bin/ditto", ["--noextattr", "--noqtn", source.path, destination.path])
        }

        return try applyInPlace(
            app: destination,
            key: key,
            teamID: teamID,
            identity: identity,
            profile: profile,
            log: log
        )
    }

    /// Re-applies anchors, entitlements, and signature to an existing copy.
    /// Used both after the initial copy and when the vendor updater replaces the bundle.
    static func applyInPlace(
        app: URL,
        key: ActivationKey,
        teamID: String,
        identity: String,
        profile: ProvisioningProfile?,
        log: (String) -> Void
    ) throws -> PatchSummary {
        guard AppBundle.isAlcove(app) else {
            throw WorkbenchError.message("不是有效的 macOS 应用：\(app.path)")
        }
        guard let executable = AppBundle.executable(at: app) else {
            throw WorkbenchError.message("应用缺少可执行文件")
        }
        let alreadyPatched = isPatched(app, publicKey: key.publicKey)
        let mainPatch = try patchBinary(
            at: executable,
            publicKey: alreadyPatched ? nil : key.publicKey,
            teamID: teamID
        )
        if !alreadyPatched {
            guard mainPatch.publicKeyHits > 0, mainPatch.urlHits > 0 else {
                throw WorkbenchError.message("目标二进制中找不到授权锚点，可能不是 Alcove 或版本已变化")
            }
        }
        log("主程序：公钥 \(mainPatch.publicKeyHits) 处，接口地址 \(mainPatch.urlHits) 处，Team \(mainPatch.teamHits) 处")

        var nested: [String] = []
        for binary in nestedExecutables(in: app, mainExecutable: executable) {
            let patch = try patchBinary(at: binary, publicKey: nil, teamID: teamID)
            if patch.teamHits > 0 {
                nested.append(binary.lastPathComponent)
            }
        }
        if !nested.isEmpty {
            log("嵌套组件：\(nested.joined(separator: "、"))")
        }

        try removeSignatures(in: app)
        if let profile {
            try FileManager.default.copyItem(
                at: profile.url,
                to: app.appendingPathComponent("Contents/embedded.provisionprofile")
            )
            log("嵌入描述文件：\(profile.name)")
        }

        let entitlements = try writeEntitlements(teamID: teamID)
        defer { try? FileManager.default.removeItem(at: entitlements) }

        log("签名：\(identity)")
        try Command.run("/usr/bin/codesign", [
            "--force", "--deep",
            "--sign", identity,
            "--options", "runtime",
            "--timestamp=none",
            "--entitlements", entitlements.path,
            app.path,
        ])
        try Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try? Command.run("/usr/bin/xattr", ["-cr", app.path])
        log("签名校验通过")

        return PatchSummary(
            publicKeyHits: mainPatch.publicKeyHits,
            urlHits: mainPatch.urlHits,
            teamHits: mainPatch.teamHits,
            nestedBinaries: nested
        )
    }

    static func isPatched(_ app: URL, publicKey: String) -> Bool {
        guard let executable = AppBundle.executable(at: app),
              let data = try? Data(contentsOf: executable) else { return false }
        return data.range(of: Data(publicKey.utf8)) != nil
    }

    static func signedTeam(_ app: URL) -> String? {
        guard let output = try? Command.run(
            "/usr/bin/codesign", ["-dv", "--verbose=4", app.path], allowFailure: true
        ) else { return nil }
        for line in output.components(separatedBy: .newlines) where line.hasPrefix("TeamIdentifier=") {
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        return nil
    }

    // MARK: - Internals

    private static func patchBinary(
        at url: URL,
        publicKey: String?,
        teamID: String
    ) throws -> PatchSummary {
        var data = try Data(contentsOf: url)
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        var keyHits = 0
        if let publicKey {
            keyHits = replace(
                &data,
                needle: vendorPublicKey,
                replacement: Data(publicKey.utf8)
            )
        }
        let urlHits = replace(&data, needle: vendorURL, replacement: localURL)
        let teamHits = replace(&data, needle: vendorTeam, replacement: Data(teamID.utf8))
        try data.write(to: url)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return PatchSummary(
            publicKeyHits: keyHits,
            urlHits: urlHits,
            teamHits: teamHits,
            nestedBinaries: []
        )
    }

    private static func replace(_ data: inout Data, needle: Data, replacement: Data) -> Int {
        guard needle.count == replacement.count, !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = data.startIndex
        while cursor < data.endIndex,
              let range = data.range(of: needle, in: cursor..<data.endIndex) {
            data.replaceSubrange(range, with: replacement)
            count += 1
            cursor = range.lowerBound + replacement.count
        }
        return count
    }

    private static func nestedExecutables(in app: URL, mainExecutable: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: app,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let item as URL in enumerator {
            guard item.path.contains("/Contents/MacOS/") else { continue }
            guard item != mainExecutable else { continue }
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(item)
        }
        return result
    }

    private static func removeSignatures(in app: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: app, includingPropertiesForKeys: nil) else { return }
        var signatureDirectories: [URL] = []
        for case let item as URL in enumerator where item.lastPathComponent == "_CodeSignature" {
            signatureDirectories.append(item)
        }
        for directory in signatureDirectories {
            try? fileManager.removeItem(at: directory)
        }
        let profile = app.appendingPathComponent("Contents/embedded.provisionprofile")
        try? fileManager.removeItem(at: profile)
    }

    private static func writeEntitlements(teamID: String) throws -> URL {
        let appIdentifier = "\(teamID).\(alcoveBundleID)"
        let entitlements: [String: Any] = [
            "com.apple.application-identifier": appIdentifier,
            "com.apple.developer.team-identifier": teamID,
            "keychain-access-groups": [appIdentifier],
            "com.apple.security.app-sandbox": false,
            "com.apple.security.network.client": true,
            "com.apple.security.automation.apple-events": true,
            "com.apple.security.personal-information.calendars": true,
            "com.apple.security.personal-information.location": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alcove-entitlements-\(UUID().uuidString).plist")
        try data.write(to: url)
        return url
    }
}
