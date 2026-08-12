import Foundation

/// How the UI reaches the DJOneHub core.
///
/// Today the only implementation talks to a child process over pipes. Keeping
/// the UI behind this protocol is what allows an iPad build to swap in a
/// DriverKit-backed transport later without touching any view code — which
/// matters because iOS forbids spawning child processes at all, so that build
/// cannot reuse this one.
protocol ModemTransport: Sendable {
    func health() async throws -> Health
    func status() async throws -> StatusResult
    func executeAT(_ command: String) async throws -> String

    func listSMS() async throws -> [ReceivedSMS]
    func smsStatus() async throws -> SMSStatus
    func refreshSMS() async throws -> RefreshResult
    func clearModuleSMS() async throws -> ClearResult
    func sendSMS(phone: String, message: String) async throws -> SendResult
}

extension ModemTransport {
    /// Polls until the core answers or the deadline passes. Readiness is a
    /// property of the connection rather than of how the core was launched, so
    /// it lives here rather than alongside the process handling.
    func waitUntilReady(timeout: TimeInterval = 15) async throws -> Health {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try await health()
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw TransportError.coreUnavailable(lastError?.localizedDescription ?? "启动超时")
    }
}

enum TransportError: LocalizedError {
    /// The core answered, and said the request failed.
    case core(String)
    /// The core could not be reached at all.
    case coreUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .core(message):
            message
        case let .coreUnavailable(detail):
            "无法连接 DJOneHub 核心：\(detail)"
        }
    }
}
