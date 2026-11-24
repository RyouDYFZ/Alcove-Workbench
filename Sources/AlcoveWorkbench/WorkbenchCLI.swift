import Foundation

enum WorkbenchCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--prepare")
            || arguments.contains("--repair")
            || arguments.contains("--install-agent")
            || arguments.contains("--remove-agent")
            || arguments.contains("--serve")
            || arguments.contains("--seed")
            || arguments.contains("--install-service")
            || arguments.contains("--remove-service")
            || arguments.contains("--check-update")
            || arguments.contains("--apply-update")
    }

    static func run(_ arguments: [String]) -> Int32 {
        do {
            if arguments.contains("--seed") {
                try seedActivation()
            } else if arguments.contains("--install-service") {
                try installService()
            } else if arguments.contains("--remove-service") {
                try ServiceAgent.remove()
                print("• 已移除常驻服务")
            } else if arguments.contains("--serve") {
                try serve()
            } else if arguments.contains("--apply-update") {
                try applyUpdate(force: arguments.contains("--force"))
            } else if arguments.contains("--check-update") {
                try checkUpdate()
            } else if arguments.contains("--install-agent") {
                try installAgent()
            } else if arguments.contains("--remove-agent") {
                try RepairAgent.remove()
                print("• 已移除自动修复代理")
            } else if arguments.contains("--repair") {
                try repair()
            } else {
                try prepare(arguments)
            }
            return 0
        } catch {
            let message = "失败：\(error.localizedDescription)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            appendLog(message)
            return 1
        }
    }

    private static func prepare(_ arguments: [String]) throws {
        let key = try ActivationKey.loadOrCreate()
        let source = URL(fileURLWithPath: value(arguments, "--source") ?? Paths.defaultSource.path)
        let destination = URL(fileURLWithPath: value(arguments, "--dest") ?? Paths.destination.path)
        let identity = try resolveIdentity(arguments)
        let profile = try resolveProfile(arguments, teamID: identity.teamID)
        try Paths.prepareDirectories()

        print("• 使用签名身份 \(identity.commonName)")
        let summary = try Patcher.prepare(
            source: source,
            destination: destination,
            key: key,
            teamID: identity.teamID,
            identity: identity.sha1,
            profile: profile,
            log: { print("• \($0)") }
        )
        print("• 完成：\(destination.path)")

        var config = WorkbenchConfig.load() ?? WorkbenchConfig(
            sourceApp: source.path,
            destinationApp: destination.path,
            identity: identity.sha1,
            teamID: identity.teamID,
            profilePath: profile?.url.path,
            activated: false
        )
        config.sourceApp = source.path
        config.destinationApp = destination.path
        config.identity = identity.sha1
        config.teamID = identity.teamID
        config.profilePath = profile?.url.path
        if summary.publicKeyHits == 0 { config.activated = false }
        try config.save()
        appendLog("prepared \(destination.path)")
    }

    private static func seedActivation() throws {
        guard let config = WorkbenchConfig.load() else {
            throw WorkbenchError.message("缺少激活配置，请先执行一次准备")
        }
        guard let identity = SigningAssets.identities().first(where: { $0.sha1 == config.identity }) else {
            throw WorkbenchError.message("找不到原签名身份")
        }
        let profile = config.profilePath.flatMap { Profiles.decode(URL(fileURLWithPath: $0)) }
            ?? Profiles.bestProfile(for: identity.teamID)
        let instance = try SilentActivation.activate(
            licenseKey: config.licenseKey ?? "ALCOVE-LOCAL-ACTIVATION",
            identity: identity,
            profile: profile
        )
        print("• 已写入激活状态（instance \(instance)）")
    }

    private static func installService() throws {
        guard let executable = Bundle.main.executableURL else {
            throw WorkbenchError.message("找不到自身可执行文件")
        }
        try ServiceAgent.install(executable: executable)
        print("• 已安装常驻授权服务（ryo.AlcoveWorkbench.serve）")
    }

    private static func serve() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let key = try ActivationKey.load()
        let hardware = try Device.hardwareUUID()
        let config = WorkbenchConfig.load()
        let server = try LocalActivationServer(
            key: key,
            hardwareUUID: hardware,
            licenseKey: config?.licenseKey ?? "",
            licenseName: config?.licenseName ?? "Local Activation"
        )
        server.onRequest = { print("• \($0)") }
        try server.start()
        print("• 本地服务已启动：127.0.0.1:\(LocalActivationServer.port)")
        RunLoop.main.run()
    }

    private static func fetchUpdate() throws -> DownloadedUpdate {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<DownloadedUpdate, Error>?
        Task {
            do {
                result = .success(try await UpdateService.fetchLatest())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch result {
        case let .success(update):
            return update
        case let .failure(error):
            throw error
        case .none:
            throw WorkbenchError.message("检查更新未返回结果")
        }
    }

    private static func checkUpdate() throws {
        let update = try fetchUpdate()
        defer { update.cleanUp() }
        print("• 官方最新版本：\(update.displayVersion)")
    }

    private static func applyUpdate(force: Bool) throws {
        guard let config = WorkbenchConfig.load() else {
            throw WorkbenchError.message("缺少激活配置，请先在图形界面执行一次激活")
        }
        let destination = URL(fileURLWithPath: config.destinationApp)
        let key = try ActivationKey.load()
        guard let identity = SigningAssets.identities().first(where: { $0.sha1 == config.identity }) else {
            throw WorkbenchError.message("找不到原签名身份")
        }
        let update = try fetchUpdate()
        defer { update.cleanUp() }
        let current = AppBundle.version(at: destination) ?? "未安装"
        print("• 官方最新：\(update.displayVersion)；本地副本：\(current)")
        if !force && update.displayVersion == current {
            print("• 已是最新版本")
            return
        }
        let profile = config.profilePath.flatMap { Profiles.decode(URL(fileURLWithPath: $0)) }
            ?? Profiles.bestProfile(for: identity.teamID)
        _ = try Patcher.prepare(
            source: update.appURL,
            destination: destination,
            key: key,
            teamID: identity.teamID,
            identity: identity.sha1,
            profile: profile,
            log: { print("• \($0)") }
        )
        try config.save()
        print("• 已更新到 \(update.displayVersion)，本地激活保留")
    }

    private static func installAgent() throws {
        guard let config = WorkbenchConfig.load(), let executable = Bundle.main.executableURL else {
            throw WorkbenchError.message("缺少激活配置")
        }
        try RepairAgent.install(executable: executable, destinationApp: config.destinationApp)
        print("• 已安装自动修复代理")
    }

    private static func repair() throws {
        guard let config = WorkbenchConfig.load() else {
            throw WorkbenchError.message("缺少激活配置，请先在图形界面执行一次激活")
        }
        let key = try ActivationKey.load()
        let destination = URL(fileURLWithPath: config.destinationApp)
        guard let identity = SigningAssets.identities().first(where: { $0.sha1 == config.identity }) else {
            throw WorkbenchError.message("找不到原签名身份")
        }
        let profile = config.profilePath.flatMap { Profiles.decode(URL(fileURLWithPath: $0)) }
            ?? Profiles.bestProfile(for: config.teamID)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: destination.path) {
            let source = URL(fileURLWithPath: config.sourceApp)
            print("• 本地副本不存在，重新创建")
            _ = try Patcher.prepare(
                source: source,
                destination: destination,
                key: key,
                teamID: identity.teamID,
                identity: identity.sha1,
                profile: profile,
                log: { print("• \($0)") }
            )
            appendLog("recreated \(destination.path)")
            return
        }

        if Patcher.isPatched(destination, publicKey: key.publicKey),
           Patcher.signedTeam(destination) == identity.teamID {
            print("• 补丁与签名均有效，无需修复")
            return
        }

        print("• 检测到更新或签名变化，重新应用")
        _ = try Patcher.applyInPlace(
            app: destination,
            key: key,
            teamID: identity.teamID,
            identity: identity.sha1,
            profile: profile,
            log: { print("• \($0)") }
        )
        appendLog("repaired \(destination.path)")
    }

    private static func resolveIdentity(_ arguments: [String]) throws -> SigningIdentity {
        let identities = SigningAssets.identities()
        if let sha = value(arguments, "--identity"),
           let match = identities.first(where: { $0.sha1 == sha || $0.commonName == sha }) {
            return match
        }
        if let match = identities.first(where: { Profiles.bestProfile(for: $0.teamID) != nil }) {
            return match
        }
        throw WorkbenchError.message("没有可用的 macOS 开发签名身份或描述文件")
    }

    private static func resolveProfile(_ arguments: [String], teamID: String) throws -> ProvisioningProfile? {
        if let path = value(arguments, "--profile") {
            guard let profile = Profiles.decode(URL(fileURLWithPath: path)) else {
                throw WorkbenchError.message("无法读取描述文件：\(path)")
            }
            return profile
        }
        return Profiles.bestProfile(for: teamID)
    }

    private static func value(_ arguments: [String], _ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func appendLog(_ line: String) {
        try? Paths.prepareDirectories()
        let url = Paths.logDirectory.appendingPathComponent("repair.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("[\(stamp)] \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }
}
