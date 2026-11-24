import CryptoKit
import Foundation
import Network

/// Loopback-only stand-in for api.tryalcove.com. It mints tokens with the local
/// Ed25519 key embedded in the patched app, so no vendor material is involved.
final class LocalActivationServer {
    static let port: UInt16 = 8199
    static let tokenLifetime: TimeInterval = 50 * 365 * 24 * 60 * 60

    private let signingKey: Curve25519.Signing.PrivateKey
    private let publicKeyBase64: String
    private let hardwareUUID: String
    private let instanceName: String
    private let instanceModel: String
    private let queue = DispatchQueue(label: "ryo.AlcoveWorkbench.server")
    private var listener: NWListener?
    private let licenseLock = NSLock()
    private var configuredKey: String
    private var configuredName: String

    private(set) var isRunning = false
    var onRequest: ((String) -> Void)?

    init(key: ActivationKey, hardwareUUID: String, licenseKey: String, licenseName: String) throws {
        let signingKey = try key.signingKey()
        self.signingKey = signingKey
        self.publicKeyBase64 = signingKey.publicKey.rawRepresentation.base64EncodedString()
        self.hardwareUUID = hardwareUUID
        self.instanceName = Device.computerName()
        self.instanceModel = Device.modelIdentifier()
        self.configuredKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredName = licenseName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateLicense(key: String, name: String) {
        licenseLock.lock()
        configuredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        licenseLock.unlock()
    }

    private var currentLicense: (key: String, name: String) {
        licenseLock.lock()
        defer { licenseLock.unlock() }
        return (configuredKey, configuredName)
    }

    func start() throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw WorkbenchError.message("本地端口无效")
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw WorkbenchError.message("无法创建本地监听：\(error.localizedDescription)")
        }

        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case let .failed(error):
                failure = error.localizedDescription
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) != .timedOut else {
            listener.cancel()
            throw WorkbenchError.message("本地服务启动超时")
        }
        if let failure {
            listener.cancel()
            throw WorkbenchError.message("本地端口 \(Self.port) 不可用：\(failure)")
        }
        self.listener = listener
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }
            if let request = HTTPRequest.parse(accumulated) {
                self.respond(to: request, on: connection)
                return
            }
            if error != nil || isComplete || accumulated.count > 1_048_576 {
                connection.cancel()
                return
            }
            self.read(connection, buffer: accumulated)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let (status, body) = route(request)
        onRequest?("\(request.method) \(request.path) → \(status)")
        Self.appendRequestLog("\(request.method) \(request.path) → \(status)")
        let header = [
            "HTTP/1.1 \(status) \(HTTPStatus.reason(status))",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) -> (Int, Data) {
        let rawPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let path = rawPath.hasPrefix("/api/") ? String(rawPath.dropFirst(4)) : rawPath

        if request.method == "GET", path == "/health" {
            return json(200, [
                "status": "ok",
                "mode": "local-activation",
                "public_key": publicKeyBase64,
            ])
        }
        if request.method == "GET", path.hasPrefix("/license/"), path.hasSuffix("/instances") {
            let start = path.index(path.startIndex, offsetBy: "/license/".count)
            let end = path.index(path.endIndex, offsetBy: -"/instances".count)
            let key = start < end
                ? String(path[start..<end]).removingPercentEncoding ?? ""
                : ""
            return json(200, [instanceValue(licenseKey: key, name: instanceName, model: instanceModel)])
        }
        if request.method == "GET", path.hasPrefix("/trial/") {
            return json(404, ["message": "Trial not found."])
        }
        guard request.method == "POST" else {
            return json(405, ["message": "Method not allowed"])
        }
        guard let body = request.jsonObject, let rawKey = body["license_key"] as? String else {
            return json(422, ["message": "Invalid license key"])
        }
        let requestedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = currentLicense.key
        if !configured.isEmpty, requestedKey != configured {
            return json(422, ["message": "License key mismatch"])
        }
        let key = configured.isEmpty ? requestedKey : configured
        guard !key.isEmpty else {
            return json(422, ["message": "Invalid license key"])
        }

        switch path {
        case "/license/validate":
            if let hardware = body["hardware_uuid"] as? String,
               hardware.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != hardwareUUID {
                return json(422, ["message": "Hardware UUID mismatch"])
            }
            return json(200, validateResponse(licenseKey: key))

        case "/license/issue-token":
            let requestedInstance = (body["instance_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRefresh = requestedInstance != nil
            if !isRefresh {
                let name = (body["instance_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let model = (body["instance_model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty || model.isEmpty {
                    return json(422, ["message": "Missing instance metadata"])
                }
            }
            guard let response = try? issueResponse(
                licenseKey: key,
                instanceID: requestedInstance?.isEmpty == false ? requestedInstance : nil
            ) else {
                return json(500, ["message": "Local token signing failed"])
            }
            return json(200, response)

        case "/license/deactivate":
            return json(200, ["message": "Local activation deactivated"])

        default:
            return json(404, ["message": "Not found"])
        }
    }

    // MARK: - Responses

    private func validateResponse(licenseKey: String) -> [String: Any] {
        [
            "key": licenseKey,
            "active": true,
            "beta": false,
            "name": currentLicense.name.isEmpty ? "Local Activation" : currentLicense.name,
            "email": NSNull(),
            "limit": 3,
            "usage": 1,
            "instance": instanceValue(licenseKey: licenseKey, name: instanceName, model: instanceModel),
            "instances": [instanceValue(licenseKey: licenseKey, name: instanceName, model: instanceModel)],
        ]
    }

    private func issueResponse(licenseKey: String, instanceID: String?) throws -> [String: Any] {
        let now = Date()
        let expiresAt = now.addingTimeInterval(Self.tokenLifetime)
        let token = try makeToken(
            licenseKey: licenseKey,
            issuedAt: now,
            expiresAt: expiresAt,
            instanceID: instanceID
        )
        let instance = instanceValue(
            licenseKey: licenseKey,
            name: instanceName,
            model: instanceModel,
            instanceID: instanceID
        )
        return [
            "key": licenseKey,
            "active": true,
            "beta": false,
            "name": currentLicense.name.isEmpty ? "Local Activation" : currentLicense.name,
            "limit": 3,
            "usage": 1,
            "instance": instance,
            "instances": [instance],
            "includesInstances": true,
            "token": token,
            "token_expires_at": Self.iso8601(expiresAt),
        ]
    }

    private func instanceValue(
        licenseKey: String,
        name: String,
        model: String,
        instanceID: String? = nil
    ) -> [String: Any] {
        [
            "id": instanceID ?? Self.instanceID(licenseKey: licenseKey, hardwareUUID: hardwareUUID),
            "name": name,
            "model": model,
        ]
    }

    private func makeToken(
        licenseKey: String,
        issuedAt: Date,
        expiresAt: Date,
        instanceID: String? = nil
    ) throws -> String {
        let header: [String: Any] = ["alg": "EdDSA", "kid": "v1"]
        let payload: [String: Any] = [
            "v": 1,
            "iss": "Alcove",
            "sub": instanceID ?? Self.instanceID(licenseKey: licenseKey, hardwareUUID: hardwareUUID),
            "lkey": licenseKey,
            "hwid": hardwareUUID,
            "active": true,
            "beta": false,
            "limit": 3,
            "usage": 1,
            "iname": instanceName,
            "imodel": instanceModel,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
            "kid": "v1",
        ]
        let headerSegment = Self.base64URL(try Self.encode(header))
        let payloadSegment = Self.base64URL(try Self.encode(payload))
        let signingInput = Data("\(headerSegment).\(payloadSegment)".utf8)
        let signature = try signingKey.signature(for: signingInput)
        return "\(headerSegment).\(payloadSegment).\(Self.base64URL(signature))"
    }

    private func json(_ status: Int, _ object: Any) -> (Int, Data) {
        let data = (try? Self.encode(object)) ?? Data("{}".utf8)
        return (status, data)
    }

    // MARK: - Helpers

    static func appendRequestLog(_ line: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AlcoveWorkbench", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("requests.log")
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

    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func instanceID(licenseKey: String, hardwareUUID: String) -> String {
        let digest = SHA256.hash(data: Data("alcove-local-activation:\(licenseKey):\(hardwareUUID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}

enum HTTPStatus {
    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
    var jsonObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerText = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), body: body)
    }
}
