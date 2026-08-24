import Foundation

/// Drives the core over the pipes of a child process.
///
/// Nothing is bound to a port, so no other process on the machine can reach the
/// module through this channel. It also removes the need to tear the core down
/// explicitly: when this app exits, the write end of the pipe closes, the core
/// reads EOF and stops on its own — including after a crash or a force quit,
/// where no shutdown handler of ours would have run.
final class StdioTransport: ModemTransport, @unchecked Sendable {
    private let process = Process()
    private let toCore = Pipe()
    private let fromCore = Pipe()

    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private var terminationReason: String?

    /// Events arrive on the same pipe as the answers and are told apart by
    /// shape: an answer carries "id", an event carries "event". Until this
    /// existed the event frames failed to decode as answers and were dropped
    /// without trace, which is where the eSIM download progress went.
    let events: AsyncStream<CoreEvent>
    private let emitEvent: @Sendable (CoreEvent) -> Void

    init(executable: URL, demo: Bool) {
        var send: (@Sendable (CoreEvent) -> Void)!
        events = AsyncStream { continuation in
            send = { continuation.yield($0) }
            continuation.onTermination = { _ in }
        }
        emitEvent = send

        process.executableURL = executable
        process.arguments = demo ? ["-stdio", "-demo"] : ["-stdio"]
        process.standardInput = toCore
        process.standardOutput = fromCore
        // Leave standardError alone so the core's logs land in the app's own
        // stderr rather than being swallowed.
    }

    func start() throws {
        fromCore.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                self?.fail(with: "核心已关闭输出")
                return
            }
            self?.consume(chunk)
        }
        process.terminationHandler = { [weak self] proc in
            self?.fail(with: "核心进程已退出（状态码 \(proc.terminationStatus)）")
        }
        try process.run()
    }

    func stop() {
        // Closing stdin is the polite shutdown: the core sees EOF and returns.
        try? toCore.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - ModemTransport

    func health() async throws -> Health {
        try await call("health", params: Empty())
    }

    func status() async throws -> StatusResult {
        try await call("status", params: Empty())
    }

    func executeAT(_ command: String) async throws -> String {
        struct Params: Encodable { let command: String }
        struct Reply: Decodable { let response: String }
        let reply: Reply = try await call("at", params: Params(command: command))
        return reply.response
    }

    func listSMS() async throws -> [ReceivedSMS] {
        try await call("sms.list", params: Empty())
    }

    func smsStatus() async throws -> SMSStatus {
        try await call("sms.status", params: Empty())
    }

    func refreshSMS() async throws -> RefreshResult {
        try await call("sms.refresh", params: Empty())
    }

    func clearModuleSMS() async throws -> ClearResult {
        try await call("sms.clear", params: Empty())
    }

    func sendSMS(phone: String, message: String) async throws -> SendResult {
        struct Params: Encodable {
            let phone: String
            let message: String
        }
        return try await call("sms.send", params: Params(phone: phone, message: message))
    }

    func networkDiagnostic() async throws -> NetworkDiagnostic {
        try await call("network.diagnostic", params: Empty())
    }

    func networkTraffic() async throws -> TrafficSnapshot {
        try await call("network.traffic", params: Empty())
    }

    /// The core answers null when the module has no interface up, which is a
    /// state rather than a failure.
    func networkLocal() async throws -> LocalConnection? {
        try await callOptional("network.local", params: Empty())
    }

    func networkActivity() async throws -> ActivitySnapshot {
        try await call("network.activity", params: Empty())
    }

    func check4GRoute() async throws -> NetworkCheckResult {
        try await call("network.check4g", params: Empty())
    }

    func checkProxyRoute() async throws -> NetworkCheckResult {
        try await call("network.checkProxy", params: Empty())
    }

    func setUSBNetMode(_ mode: Int) async throws -> USBNetResult {
        struct Params: Encodable { let mode: Int }
        return try await call("network.usbnet", params: Params(mode: mode))
    }

    func rebootModule() async throws -> RebootResult {
        try await call("network.reboot", params: Empty())
    }

    func esimOverview() async throws -> ESIMOverviewResult {
        try await call("esim.overview", params: Empty())
    }

    func esimHealth() async throws -> ESIMHealthResult {
        try await call("esim.health", params: Empty())
    }

    func esimSwitch(iccid: String, aid: String?) async throws -> ESIMSwitchResult {
        try await call("esim.switch", params: ProfileRef(iccid: iccid, aid: aid ?? ""))
    }

    func esimDelete(iccid: String, aid: String?) async throws -> ESIMActionResult {
        try await call("esim.delete", params: ProfileRef(iccid: iccid, aid: aid ?? ""))
    }

    func esimRename(iccid: String, aid: String?, name: String) async throws -> ESIMActionResult {
        struct Params: Encodable {
            let iccid: String
            let aid: String
            let name: String
        }
        return try await call("esim.rename", params: Params(iccid: iccid, aid: aid ?? "", name: name))
    }

    func esimDownload(_ request: ESIMDownloadRequest) async throws -> ESIMActionResult {
        try await call("esim.download", params: request)
    }

    // MARK: - Protocol plumbing

    /// A card can host more than one eUICC application, so a profile is
    /// identified by its ICCID together with the AID it lives in.
    private struct ProfileRef: Encodable {
        let iccid: String
        let aid: String
    }

    private struct Empty: Encodable {}

    private struct Envelope: Encodable {
        let id: Int
        let method: String
    }

    private func call<P: Encodable, R: Decodable>(_ method: String, params: P) async throws -> R {
        try Self.decoder.decode(R.self, from: try await invoke(method, params: params))
    }

    private func invoke<P: Encodable>(_ method: String, params: P) async throws -> Data {
        let id = lock.withLock { () -> Int in
            let value = nextID
            nextID += 1
            return value
        }

        // Encode {"id":…,"method":…,"params":…} without needing a generic
        // wrapper type for every parameter shape.
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Envelope(id: id, method: method))) as? [String: Any] ?? [:]
        let encodedParams = try JSONEncoder().encode(params)
        if let paramsObject = try JSONSerialization.jsonObject(with: encodedParams) as? [String: Any],
            !paramsObject.isEmpty
        {
            object["params"] = paramsObject
        }
        var line = try JSONSerialization.data(withJSONObject: object)
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try toCore.fileHandleForWriting.write(contentsOf: line)
            } catch {
                if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) {
                    waiting.resume(throwing: TransportError.coreUnavailable(error.localizedDescription))
                }
            }
        }
    }

    private func callOptional<P: Encodable, R: Decodable>(_ method: String, params: P) async throws
        -> R?
    {
        let payload = try await invoke(method, params: params)
        if payload.isEmpty || payload == Data("null".utf8) { return nil }
        return try Self.decoder.decode(R.self, from: payload)
    }

    /// Go emits RFC 3339 with fractional seconds, which `.iso8601` rejects, and
    /// omits them when they happen to be zero — so both spellings must parse.
    private static let decoder: JSONDecoder = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "无法解析时间 \(text)"))
        }
        return decoder
    }()

    /// Accumulates output and completes a request per newline-terminated frame.
    private func consume(_ chunk: Data) {
        let frames: [Data] = lock.withLock {
            buffer.append(chunk)
            var complete: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                complete.append(buffer[buffer.startIndex ..< newline])
                buffer = buffer[buffer.index(after: newline)...]
            }
            return complete
        }
        for frame in frames where !frame.isEmpty {
            deliver(frame)
        }
    }

    private struct Response: Decodable {
        let id: Int
        let ok: Bool
        let error: String?
        let result: RawJSON?
    }

    private func deliver(_ frame: Data) {
        guard let response = try? JSONDecoder().decode(Response.self, from: frame) else {
            // No request id: this is something the core said on its own.
            if let event = try? JSONDecoder().decode(CoreEvent.self, from: frame) {
                emitEvent(event)
            }
            return
        }
        guard let waiting = lock.withLock({ pending.removeValue(forKey: response.id) }) else {
            return
        }
        if response.ok {
            // A successful call can still answer null — network.local does so
            // when the module has no interface up. Treating a missing result as
            // a failure turned that state into an error message.
            waiting.resume(returning: response.result?.data ?? Data())
        } else {
            waiting.resume(throwing: TransportError.core(response.error ?? "核心返回了失败但没有说明原因"))
        }
    }

    /// Fails every in-flight request; used when the core goes away.
    private func fail(with reason: String) {
        let waiting: [CheckedContinuation<Data, Error>] = lock.withLock {
            if terminationReason == nil { terminationReason = reason }
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        for continuation in waiting {
            continuation.resume(throwing: TransportError.coreUnavailable(reason))
        }
    }
}

/// Captures a JSON value without decoding it, so the envelope can be parsed
/// before the result's concrete type is known.
struct RawJSON: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(AnyCodable.self)
        data = try JSONSerialization.data(withJSONObject: value.value)
    }
}

private struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: AnyCodable].self) {
            value = object.mapValues(\.value)
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = NSNull()
        }
    }
}
