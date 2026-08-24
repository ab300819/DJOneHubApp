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

    func networkDiagnostic() async throws -> NetworkDiagnostic
    func networkTraffic() async throws -> TrafficSnapshot
    func networkLocal() async throws -> LocalConnection?
    func networkActivity() async throws -> ActivitySnapshot
    func check4GRoute() async throws -> NetworkCheckResult
    func checkProxyRoute() async throws -> NetworkCheckResult
    func setUSBNetMode(_ mode: Int) async throws -> USBNetResult
    func rebootModule() async throws -> RebootResult

    func esimOverview() async throws -> ESIMOverviewResult
    func esimHealth() async throws -> ESIMHealthResult
    func esimSwitch(iccid: String, aid: String?) async throws -> ESIMSwitchResult
    func esimDelete(iccid: String, aid: String?) async throws -> ESIMActionResult
    func esimRename(iccid: String, aid: String?, name: String) async throws -> ESIMActionResult
    func esimDownload(_ request: ESIMDownloadRequest) async throws -> ESIMActionResult

    func moduleNotes() async throws -> ModuleNotes
    func saveModuleNote(_ note: ModuleProfileNote) async throws -> ModuleNoteResult
    func probePhonebook() async throws -> PhonebookProbe

    /// Events the core pushes without being asked, such as eSIM download
    /// progress. The stream is unbounded in time and finishes when the core
    /// goes away; a page that only cares while it is on screen should iterate
    /// it from a task tied to its own lifetime.
    var events: AsyncStream<CoreEvent> { get }
}

/// What an SM-DP+ needs to hand over a profile.
struct ESIMDownloadRequest: Encodable, Sendable {
    var smdp: String = ""
    var matchingID: String = ""
    var confirmationCode: String = ""
    var aid: String = ""
    var imei: String = ""

    enum CodingKeys: String, CodingKey {
        case smdp, aid, imei
        case matchingID = "matching_id"
        case confirmationCode = "confirmation_code"
    }
}

/// An unsolicited message from the core. Frames carrying no request id are
/// events rather than answers, which is how the two are told apart on the one
/// channel they share.
struct CoreEvent: Decodable, Sendable {
    let event: String
    let percent: Int?
    let message: String?
}

/// The event names the core emits, matching the constants on its side.
enum CoreEventName {
    static let esimDownloadProgress = "esim.download.progress"
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
