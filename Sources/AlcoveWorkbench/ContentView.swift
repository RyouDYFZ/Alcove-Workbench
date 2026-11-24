import SwiftUI

struct ContentView: View {
    @StateObject private var model = ActivationModel()

    var body: some View {
        Form {
            Section {
                LabeledContent("应用") {
                    Text(model.destinationApp)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("版本", value: model.destinationVersion ?? "未安装")
                LabeledContent("补丁", value: model.patched ? "已应用" : "未应用")
                LabeledContent("本地服务", value: model.serverRunning ? "运行中 · 127.0.0.1:8199" : "未运行")
                LabeledContent("授权", value: model.activated ? "永久 · 本机绑定" : "未激活")
            } header: {
                Text("状态")
            }

            Section {
                TextField("授权名称", text: $model.licenseName)
                TextField("授权密钥", text: $model.licenseKey)
            } header: {
                Text("授权")
            } footer: {
                Text("名称会随令牌写入并显示在 Alcove 的授权页；密钥必须与在 Alcove 中填写的完全一致。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.identities.isEmpty {
                    LabeledContent("签名身份", value: "未找到")
                } else {
                    Picker("签名身份", selection: $model.selectedIdentity) {
                        ForEach(model.identities) { identity in
                            Text(identity.displayName).tag(identity.sha1)
                        }
                    }
                }
            } header: {
                Text("签名")
            } footer: {
                Text("直接替换 /Applications/Alcove.app：重打补丁并用本机 Apple Development 证书重签。重装 Alcove 后再点一次即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Button("一键激活") {
                        model.activate()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.identities.isEmpty)

                    Button("重新应用") {
                        model.repairNow()
                    }
                    .disabled(model.busy || model.identities.isEmpty)

                    if model.busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Button("检查官方更新") {
                        model.checkForUpdate()
                    }
                    .disabled(model.busy || model.identities.isEmpty)
                    Button("打开 Alcove") {
                        model.openAlcove()
                    }
                    .disabled(model.destinationVersion == nil)
                    Button("停止服务") {
                        model.stopServer()
                    }
                    .disabled(!model.serverRunning)
                }

                Toggle("静默激活（免粘贴，直接写入 Keychain）", isOn: Binding(
                    get: { model.silentActivation },
                    set: { model.setSilentActivation($0) }
                ))

                Toggle("Alcove 更新后自动修复", isOn: Binding(
                    get: { model.autoRepair },
                    set: { model.setAutoRepair($0) }
                ))
            }

            if !model.hint.isEmpty {
                Section {
                    Text(model.hint)
                        .font(.callout)
                }
            }

            Section {
                ScrollView {
                    Text(model.logText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            } header: {
                Text("日志")
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 660)
        .onChange(of: model.licenseKey) { _, _ in model.licenseSettingsChanged() }
        .onChange(of: model.licenseName) { _, _ in model.licenseSettingsChanged() }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
}
