import CryptoKit
import Foundation
import IOKit

enum WorkbenchError: LocalizedError {
    case message(String)
    case command(String, [String], Int32, String)

    var errorDescription: String? {
        switch self {
        case let .message(text):
            return text
        case let .command(tool, args, code, output):
            let joined = ([tool] + args).joined(separator: " ")
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(joined) 失败（退出码 \(code)）\(trimmed.isEmpty ? "" : "：\(trimmed)")"
        }
    }
}

enum Command {
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw WorkbenchError.message("无法执行 \(tool)：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 && !allowFailure {
            throw WorkbenchError.command(tool, arguments, process.terminationStatus, output)
        }
        return output
    }
}

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AlcoveWorkbench", isDirectory: true)
    static let keyFile = support.appendingPathComponent("activation-key.json")
    static let configFile = support.appendingPathComponent("config.json")
    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AlcoveWorkbench", isDirectory: true)
    static let defaultSource = URL(fileURLWithPath: "/Applications/Alcove.app")
    static let destination = URL(fileURLWithPath: "/Applications/Alcove.app", isDirectory: true)
    static let launchAgent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/ryo.AlcoveWorkbench.repair.plist")

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Key material

struct ActivationKey: Codable, Sendable {
    var privateKey: String
    var publicKey: String

    enum CodingKeys: String, CodingKey {
        case privateKey = "private_key"
        case publicKey = "public_key"
    }

    static func loadOrCreate() throws -> ActivationKey {
        try Paths.prepareDirectories()
        if let data = try? Data(contentsOf: Paths.keyFile),
           let key = try? JSONDecoder().decode(ActivationKey.self, from: data),
           key.isValid {
            return key
        }
        let fresh = try generate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(fresh)
        data.append(0x0A)
        try data.write(to: Paths.keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.keyFile.path)
        return fresh
    }

    static func load() throws -> ActivationKey {
        guard let data = try? Data(contentsOf: Paths.keyFile),
              let key = try? JSONDecoder().decode(ActivationKey.self, from: data),
              key.isValid else {
            throw WorkbenchError.message("尚未生成本地激活密钥")
        }
        return key
    }

    static func generate() throws -> ActivationKey {
        let key = Curve25519.Signing.PrivateKey()
        return ActivationKey(
            privateKey: key.rawRepresentation.base64EncodedString(),
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    var isValid: Bool {
        guard let privateData = Data(base64Encoded: privateKey),
              privateData.count == 32,
              let publicData = Data(base64Encoded: publicKey),
              publicData.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
        else { return false }
        return signingKey.publicKey.rawRepresentation == publicData
    }

    func signingKey() throws -> Curve25519.Signing.PrivateKey {
        guard let data = Data(base64Encoded: privateKey) else {
            throw WorkbenchError.message("本地激活私钥损坏")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
}

// MARK: - Persisted configuration

struct WorkbenchConfig: Codable, Sendable {
    var sourceApp: String
    var destinationApp: String
    var identity: String
    var teamID: String
    var profilePath: String?
    var activated: Bool
    var licenseKey: String?
    var licenseName: String?
    var silentActivation: Bool?

    static func load() -> WorkbenchConfig? {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return nil }
        return try? JSONDecoder().decode(WorkbenchConfig.self, from: data)
    }

    func save() throws {
        try Paths.prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.configFile, options: .atomic)
    }
}

// MARK: - Signing identities

struct SigningIdentity: Identifiable, Hashable, Sendable {
    let sha1: String
    let commonName: String
    let teamID: String

    var id: String { sha1 }
    var displayName: String { "\(commonName)（\(teamID)）" }
}

enum SigningAssets {
    static func identities() -> [SigningIdentity] {
        guard let output = try? Command.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) else {
            return []
        }
        var result: [SigningIdentity] = []
        for line in output.components(separatedBy: .newlines) {
            guard let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }
            let name = String(line[line.index(after: firstQuote)..<lastQuote])
            let prefix = line[..<firstQuote]
            let sha1 = prefix.split(separator: ")").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard sha1.count == 40, let team = teamID(forCommonName: name) else { continue }
            result.append(SigningIdentity(sha1: sha1, commonName: name, teamID: team))
        }
        return result
    }

    static func teamID(forCommonName name: String) -> String? {
        guard let pem = try? Command.run("/usr/bin/security", ["find-certificate", "-c", name, "-p"]) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-noout", "-subject"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        input.fileHandleForWriting.write(Data(pem.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let subject = String(decoding: data, as: UTF8.self)
        for part in subject.split(whereSeparator: { $0 == "," || $0 == "/" }) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("OU=") else { continue }
            let value = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let candidate = String(value.prefix { $0.isLetter || $0.isNumber })
            if candidate.count == 10 { return candidate }
        }
        return nil
    }
}

// MARK: - Provisioning profiles

struct ProvisioningProfile: Identifiable, Sendable {
    let url: URL
    let name: String
    let teamID: String
    let applicationIdentifier: String
    let platforms: [String]
    let keychainGroups: [String]
    let expiration: Date

    var id: String { url.path }
    var bundleID: String {
        applicationIdentifier.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init)
            ?? applicationIdentifier
    }
    var isWildcard: Bool { bundleID.hasSuffix("*") }
    var isMacOS: Bool { platforms.contains("OSX") || platforms.contains("macOS") }
}

enum Profiles {
    static func directories() -> [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true),
        ]
    }

    static func all() -> [ProvisioningProfile] {
        var result: [ProvisioningProfile] = []
        for directory in directories() {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension) {
                if let profile = decode(file) { result.append(profile) }
            }
        }
        return result.sorted { $0.expiration > $1.expiration }
    }

    static func decode(_ url: URL) -> ProvisioningProfile? {
        guard let raw = try? Command.run("/usr/bin/security", ["cms", "-D", "-i", url.path], allowFailure: true),
              let data = raw.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let identifier = (entitlements["com.apple.application-identifier"] as? String)
            ?? (entitlements["application-identifier"] as? String)
            ?? ""
        let teams = plist["TeamIdentifier"] as? [String] ?? []
        guard let team = teams.first, !identifier.isEmpty else { return nil }
        return ProvisioningProfile(
            url: url,
            name: (plist["Name"] as? String) ?? url.lastPathComponent,
            teamID: team,
            applicationIdentifier: identifier,
            platforms: plist["Platform"] as? [String] ?? [],
            keychainGroups: entitlements["keychain-access-groups"] as? [String] ?? [],
            expiration: (plist["ExpirationDate"] as? Date) ?? .distantPast
        )
    }

    static func bestProfile(for teamID: String) -> ProvisioningProfile? {
        let now = Date()
        let candidates = all().filter {
            $0.teamID == teamID && $0.isMacOS && $0.expiration > now
        }
        let wildcard = candidates.filter { $0.keychainGroups.contains("\(teamID).*") }
        let pool = wildcard.isEmpty ? candidates : wildcard
        if let mac = pool.first(where: {
            $0.name.contains("Mac Team Provisioning Profile") && !$0.name.contains("Catalyst")
        }) {
            return mac
        }
        return pool.first(where: { !$0.name.contains("Catalyst") }) ?? pool.first
    }
}

// MARK: - Device identity

enum Device {
    static func hardwareUUID() throws -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { throw WorkbenchError.message("无法读取 IOPlatformUUID") }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            throw WorkbenchError.message("无法读取 IOPlatformUUID")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return "Mac"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "Mac"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func computerName() -> String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Mac" : name
    }
}

// MARK: - Bundle inspection

enum AppBundle {
    static func version(at url: URL) -> String? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            return nil
        }
        return "\(version) (\(build))"
    }

    static func executable(at url: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let name = info["CFBundleExecutable"] as? String else {
            return nil
        }
        return url.appendingPathComponent("Contents/MacOS/\(name)")
    }

    static func bundleIdentifier(at url: URL) -> String? {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"]) as? String
    }

    static func isAlcove(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
            && executable(at: url) != nil
    }
}
