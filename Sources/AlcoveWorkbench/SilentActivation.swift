import CryptoKit
import Foundation

/// Writes a valid `StoredLicenseState` straight into Alcove's Keychain access group,
/// so the app starts licensed without the paste-and-click detour.
enum SilentActivation {
    static func activate(
        licenseKey: String,
        identity: SigningIdentity,
        profile: ProvisioningProfile?
    ) throws -> String {
        let hardwareUUID = try Device.hardwareUUID()
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ALCOVE-LOCAL-ACTIVATION"
            : licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = try requestToken(licenseKey: key, hardwareUUID: hardwareUUID)
        guard
            let token = issue["token"] as? String,
            let instance = issue["instance"] as? [String: Any],
            let instanceID = instance["id"] as? String,
            let expiresText = issue["token_expires_at"] as? String,
            let expires = ISO8601DateFormatter.alcove.date(from: expiresText)
        else {
            throw WorkbenchError.message("本地服务返回的令牌不完整")
        }

        let state: [String: Any] = [
            "licenseKey": (issue["key"] as? String) ?? key,
            "instanceId": instanceID.lowercased(),
            "name": (issue["name"] as? String) ?? "Local Activation",
            "beta": (issue["beta"] as? Bool) ?? false,
            "instanceName": (instance["name"] as? String) ?? Device.computerName(),
            "instanceModel": (instance["model"] as? String) ?? Device.modelIdentifier(),
            "hardwareUUID": hardwareUUID,
            "limit": (issue["limit"] as? Int) ?? 3,
            "usage": (issue["usage"] as? Int) ?? 1,
            "token": token,
            "tokenExpiresAt": expires.timeIntervalSinceReferenceDate,
        ]
        let plaintext = try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let material = "\(Patcher.alcoveBundleID):\(hardwareUUID.lowercased())"
        let symmetricKey = SymmetricKey(
            data: Data(SHA256.hash(data: Data(material.utf8)))
        )
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey)
        guard let combined = sealed.combined else {
            throw WorkbenchError.message("本地授权状态加密失败")
        }
        try seed(
            base64: combined.base64EncodedString(),
            identity: identity,
            profile: profile
        )
        return instanceID
    }

    // MARK: - Local token

    private static func requestToken(
        licenseKey: String,
        hardwareUUID: String
    ) throws -> [String: Any] {
        guard let url = URL(
            string: "http://127.0.0.1:\(LocalActivationServer.port)/api/license/issue-token"
        ) else {
            throw WorkbenchError.message("本地服务地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "license_key": licenseKey,
            "hardware_uuid": hardwareUUID,
            "instance_name": Device.computerName(),
            "instance_model": Device.modelIdentifier(),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var result: Result<[String: Any], Error>?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(WorkbenchError.message(
                    "请求本地服务失败（请确认常驻服务在运行）：\(error.localizedDescription)"
                ))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = .failure(WorkbenchError.message("本地服务返回 HTTP \(code)"))
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(WorkbenchError.message("本地服务返回了无效 JSON"))
                return
            }
            result = .success(object)
        }.resume()
        semaphore.wait()

        switch result {
        case let .success(object):
            return object
        case let .failure(error):
            throw error
        case .none:
            throw WorkbenchError.message("本地服务没有返回结果")
        }
    }

    // MARK: - Keychain seed helper

    private static func seed(
        base64: String,
        identity: SigningIdentity,
        profile: ProvisioningProfile?
    ) throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("alcove-seed-\(UUID().uuidString)", isDirectory: true)
        let app = work.appendingPathComponent("Seed.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        do {
            try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        } catch {
            throw WorkbenchError.message("无法创建临时目录：\(error.localizedDescription)")
        }
        defer { try? fileManager.removeItem(at: work) }

        let stateURL = work.appendingPathComponent("state.b64")
        try Data(base64.utf8).write(to: stateURL)

        let sourceURL = work.appendingPathComponent("seed.c")
        let accessGroup = "\(identity.teamID).\(Patcher.alcoveBundleID)"
        let source = seederSource(service: Patcher.alcoveBundleID, accessGroup: accessGroup)
        try Data(source.utf8).write(to: sourceURL)

        let executable = macos.appendingPathComponent("Seed")
        try Command.run("/usr/bin/clang", [
            "-O2", "-o", executable.path, sourceURL.path,
            "-framework", "Security", "-framework", "CoreFoundation",
        ])

        let info: [String: Any] = [
            "CFBundleExecutable": "Seed",
            "CFBundleIdentifier": Patcher.alcoveBundleID,
            "CFBundleName": "Seed",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try infoData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let profile {
            try fileManager.copyItem(
                at: profile.url,
                to: app.appendingPathComponent("Contents/embedded.provisionprofile")
            )
        }

        let entitlements: [String: Any] = [
            "com.apple.application-identifier": accessGroup,
            "com.apple.developer.team-identifier": identity.teamID,
            "keychain-access-groups": [accessGroup],
            "com.apple.security.app-sandbox": false,
        ]
        let entitlementsURL = work.appendingPathComponent("entitlements.plist")
        let entitlementsData = try PropertyListSerialization.data(
            fromPropertyList: entitlements, format: .xml, options: 0
        )
        try entitlementsData.write(to: entitlementsURL)

        try Command.run("/usr/bin/codesign", [
            "--force", "--deep", "--sign", identity.sha1,
            "--options", "runtime", "--timestamp=none",
            "--entitlements", entitlementsURL.path, app.path,
        ])
        _ = try Command.run(executable.path, [stateURL.path])
    }

    private static func seederSource(service: String, accessGroup: String) -> String {
        """
        #include <stdio.h>
        #include <stdlib.h>
        #include <Security/Security.h>
        static CFMutableDictionaryRef query(void) {
            CFMutableDictionaryRef q = CFDictionaryCreateMutable(
                0, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
            CFDictionarySetValue(q, kSecAttrService, CFStringCreateWithCString(0, "\(service)", kCFStringEncodingUTF8));
            CFDictionarySetValue(q, kSecAttrAccount, CFStringCreateWithCString(0, "licenseState", kCFStringEncodingUTF8));
            CFDictionarySetValue(q, kSecAttrAccessGroup, CFStringCreateWithCString(0, "\(accessGroup)", kCFStringEncodingUTF8));
            return q;
        }
        int main(int argc, char **argv) {
            if (argc < 2) { fprintf(stderr, "missing state file\\n"); return 2; }
            FILE *f = fopen(argv[1], "rb");
            if (!f) { perror("open"); return 1; }
            fseek(f, 0, SEEK_END);
            long size = ftell(f);
            fseek(f, 0, SEEK_SET);
            char *buffer = malloc(size);
            if (!buffer || fread(buffer, 1, size, f) != (size_t)size) { fprintf(stderr, "read\\n"); return 1; }
            fclose(f);
            CFDataRef value = CFDataCreate(0, (const UInt8 *)buffer, size);
            CFMutableDictionaryRef q = query();
            OSStatus status = SecItemUpdate(q, CFDictionaryCreate(
                0, (const void *[]){ kSecValueData }, (const void *[]){ value }, 1,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
            if (status == errSecItemNotFound) {
                CFDictionarySetValue(q, kSecValueData, value);
                status = SecItemAdd(q, NULL);
            }
            if (status != errSecSuccess) {
                fprintf(stderr, "keychain status=%d\\n", (int)status);
                return 1;
            }
            return 0;
        }
        """
    }
}

extension ISO8601DateFormatter {
    static let alcove: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
