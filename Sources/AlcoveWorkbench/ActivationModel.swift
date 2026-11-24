import AppKit
import Combine
import Foundation

@MainActor
final class ActivationModel: ObservableObject {
    @Published var sourceApp: String
    @Published var destinationApp: String
    @Published var identities: [SigningIdentity] = []
    @Published var selectedIdentity: String = ""
    @Published var logText: String = ""
    @Published var busy = false
    @Published var serverRunning = false
    @Published var activated = false
    @Published var autoRepair = false
    @Published var errorMessage: String?
    @Published var hint: String = ""
    @Published var patched = false
    @Published var licenseKey: String = "ALCOVE-LOCAL-ACTIVATION"
    @Published var licenseName: String = "Local Activation"
    @Published var silentActivation: Bool = true

    private var config: WorkbenchConfig?
    private var licenseRestartTask: Task<Void, Never>?

    private var sourceURL: URL { URL(fileURLWithPath: sourceApp) }
    private var destinationURL: URL { URL(fileURLWithPath: destinationApp) }

    var sourceVersion: String? { AppBundle.version(at: sourceURL) }
    var destinationVersion: String? { AppBundle.version(at: destinationURL) }

    init() {
        let loaded = WorkbenchConfig.load()
        config = loaded
        sourceApp = loaded?.sourceApp ?? Paths.defaultSource.path
        destinationApp = loaded?.destinationApp ?? Paths.destination.path
        activated = loaded?.activated ?? false
        if let key = loaded?.licenseKey, !key.isEmpty { licenseKey = key }
        if let name = loaded?.licenseName, !name.isEmpty { licenseName = name }
        if let silent = loaded?.silentActivation { silentActivation = silent }
        selectedIdentity = loaded?.identity ?? ""
        identities = SigningAssets.identities()
        if identities.contains(where: { $0.sha1 == selectedIdentity }) == false {
            selectedIdentity = identities.first(where: { Profiles.bestProfile(for: $0.teamID) != nil })?.sha1
                ?? identities.first?.sha1
                ?? ""
        }
        autoRepair = RepairAgent.isInstalled
        serverRunning = ServiceAgent.health()
        refreshStatus()
        append("就绪。默认使用 /Applications/Alcove.app。")
        if let sourceVersion, let destinationVersion, sourceVersion != destinationVersion {
            hint = "源 App 已更新至 \(sourceVersion)，本地副本仍是 \(destinationVersion)。点击“重新应用”即可沿用现有激活。"
        }
        if activated {
            startServerIfPossible()
        }
    }

    // MARK: - Actions

    func activate() {
        guard !busy else { return }
        guard let identity = identities.first(where: { $0.sha1 == selectedIdentity }) else {
            errorMessage = "没有可用的签名身份。请确认本机已登录 Apple 开发者账号。"
            return
        }
        busy = true
        errorMessage = nil
        hint = ""
        Task {
            do {
                try startServer()
                append("本地服务已启动：127.0.0.1:\(LocalActivationServer.port)")
                quitRunningCopy()
                let output = try await runCLI([
                    "--prepare",
                    "--source", sourceApp,
                    "--dest", destinationApp,
                    "--identity", identity.sha1,
                    "--team", identity.teamID,
                ])
                append(output)
                activated = true
                patched = Patcher.isPatched(destinationURL, publicKey: (try? ActivationKey.load())?.publicKey ?? "")
                saveConfig()
                let seeded = await seedIfEnabled()
                if !seeded { copyLicenseKey() }
                quitRunningCopy()
                NSWorkspace.shared.open(destinationURL)
                hint = seeded
                    ? "已静默写入激活状态，Alcove 打开即已授权（授权名：\(licenseName)）。"
                    : "已打开 Alcove。进入 设置 → License：粘贴密钥（已在剪贴板）并点击 Activate License。授权名：\(licenseName)。"
            } catch {
                errorMessage = error.localizedDescription
                append("✗ \(error.localizedDescription)")
            }
            busy = false
        }
    }

    func repairNow() {
        guard !busy, let identity = identities.first(where: { $0.sha1 == selectedIdentity }) else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                try startServer()
                quitRunningCopy()
                let output = try await runCLI([
                    "--prepare",
                    "--source", sourceApp,
                    "--dest", destinationApp,
                    "--identity", identity.sha1,
                    "--team", identity.teamID,
                ])
                append(output)
                patched = Patcher.isPatched(destinationURL, publicKey: (try? ActivationKey.load())?.publicKey ?? "")
                saveConfig()
                let seeded = await seedIfEnabled()
                hint = seeded ? "已重新打补丁并写入激活状态。" : "已重新应用补丁并签名。"
            } catch {
                errorMessage = error.localizedDescription
                append("✗ \(error.localizedDescription)")
            }
            busy = false
        }
    }

    func checkForUpdate() {
        guard !busy else { return }
        guard let identity = identities.first(where: { $0.sha1 == selectedIdentity }) else {
            errorMessage = "没有可用的签名身份。"
            return
        }
        busy = true
        errorMessage = nil
        Task {
            var update: DownloadedUpdate?
            do {
                append("正在检查官方更新…")
                update = try await UpdateService.fetchLatest()
                defer { update?.cleanUp() }
                guard let update else { return }
                let current = destinationVersion ?? "未安装"
                append("官方最新：\(update.displayVersion)；本地副本：\(current)")
                if update.displayVersion == current {
                    hint = "已经是最新版本（\(current)）。"
                } else {
                    let alert = NSAlert()
                    alert.messageText = "发现 Alcove 新版本"
                    alert.informativeText = "官方最新 \(update.displayVersion)，本地 \(current)。更新后会重新打补丁并签名，现有激活保留。"
                    alert.addButton(withTitle: "更新")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        try startServer()
                        quitRunningCopy()
                        let output = try await runCLI([
                            "--prepare",
                            "--source", update.appURL.path,
                            "--dest", destinationApp,
                            "--identity", identity.sha1,
                            "--team", identity.teamID,
                        ])
                        append(output)
                        saveConfig()
                        _ = await seedIfEnabled()
                        quitRunningCopy()
                        NSWorkspace.shared.open(destinationURL)
                        hint = "已更新到 \(update.displayVersion)，激活状态已写入。"
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                append("✗ \(error.localizedDescription)")
            }
            busy = false
        }
    }

    func setSilentActivation(_ enabled: Bool) {
        silentActivation = enabled
        saveConfig()
        append(enabled ? "已启用静默激活" : "已关闭静默激活（改用粘贴密钥）")
    }

    private func seedIfEnabled() async -> Bool {
        guard silentActivation else { return false }
        do {
            let output = try await runCLI(["--seed"])
            append(output)
            return true
        } catch {
            append("✗ 静默激活失败：\(error.localizedDescription)")
            return false
        }
    }

    private func quitRunningCopy() {
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.henrikruscon.Alcove"
        ) {
            application.terminate()
        }
    }

    func openAlcove() {
        NSWorkspace.shared.open(destinationURL)
        hint = "如果 Alcove 提示未激活：设置 → License，粘贴密钥（已在剪贴板）后点击 Activate License。"
    }

    func stopServer() {
        do {
            try ServiceAgent.remove()
        } catch {
            errorMessage = error.localizedDescription
        }
        serverRunning = false
        append("本地服务已停止。注意：服务未运行时打开 License 页面会触发刷新失败并清除授权。")
    }

    func licenseSettingsChanged() {
        saveConfig()
        licenseRestartTask?.cancel()
        licenseRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.serverRunning,
                  let executable = Bundle.main.executableURL else { return }
            try? ServiceAgent.install(executable: executable)
        }
    }

    func setAutoRepair(_ enabled: Bool) {
        do {
            if enabled {
                guard let executable = Bundle.main.executableURL else {
                    throw WorkbenchError.message("找不到自身可执行文件")
                }
                try RepairAgent.install(executable: executable, destinationApp: destinationApp)
            } else {
                try RepairAgent.remove()
            }
            autoRepair = enabled
            append(enabled ? "已启用更新后自动修复" : "已关闭更新后自动修复")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Status

    func refreshStatus() {
        let key = try? ActivationKey.load()
        patched = key.map { Patcher.isPatched(destinationURL, publicKey: $0.publicKey) } ?? false
        if let config, config.activated != activated {
            self.config?.activated = activated
        }
    }

    // MARK: - Server

    private func startServer() throws {
        if ServiceAgent.health() {
            serverRunning = true
            return
        }
        guard let executable = Bundle.main.executableURL else {
            throw WorkbenchError.message("找不到自身可执行文件")
        }
        // The service must read the current license settings, so always restart it.
        try ServiceAgent.install(executable: executable)
        for _ in 0..<30 {
            if ServiceAgent.health() {
                serverRunning = true
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw WorkbenchError.message("本地服务未能在 127.0.0.1:\(LocalActivationServer.port) 启动")
    }

    private func startServerIfPossible() {
        do {
            try startServer()
        } catch {
            append("本地服务未启动：\(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func saveConfig() {
        var updated = WorkbenchConfig.load() ?? config ?? WorkbenchConfig(
            sourceApp: sourceApp,
            destinationApp: destinationApp,
            identity: selectedIdentity,
            teamID: identities.first(where: { $0.sha1 == selectedIdentity })?.teamID ?? "",
            profilePath: nil,
            activated: true
        )
        updated.sourceApp = sourceApp
        updated.destinationApp = destinationApp
        updated.identity = selectedIdentity
        updated.teamID = identities.first(where: { $0.sha1 == selectedIdentity })?.teamID ?? updated.teamID
        updated.activated = activated
        updated.licenseKey = licenseKey
        updated.licenseName = licenseName
        updated.silentActivation = silentActivation
        do {
            try updated.save()
            config = updated
        } catch {
            append("配置保存失败：\(error.localizedDescription)")
        }
    }

    private func copyLicenseKey() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(licenseKey.isEmpty ? "ALCOVE-LOCAL-ACTIVATION" : licenseKey, forType: .string)
    }

    private func append(_ line: String) {
        logText += line.hasSuffix("\n") ? line : line + "\n"
        if logText.count > 20_000 {
            logText = String(logText.suffix(18_000))
        }
    }

    private func runCLI(_ arguments: [String]) async throws -> String {
        guard let executable = Bundle.main.executableURL else {
            throw WorkbenchError.message("找不到自身可执行文件")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try Command.run(executable.path, arguments)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
