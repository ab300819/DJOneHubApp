import Foundation

/// One message read from the module.
struct ReceivedSMS: Decodable, Sendable, Identifiable {
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date

    /// The core has no message identifier, so rows are keyed by the fields that
    /// together make a message unique in practice.
    var id: String { "\(timestamp.timeIntervalSince1970)-\(sender)-\(content.hashValue)" }
}

/// The state of the background polling that feeds the inbox.
struct SMSStatus: Decodable, Sendable {
    let count: Int
    let polling: Bool
    let pollIntervalS: Int
    let autoCleanupME: Bool
    let lastPollError: String

    enum CodingKeys: String, CodingKey {
        case count, polling
        case pollIntervalS = "poll_interval_s"
        case autoCleanupME = "auto_cleanup_me"
        case lastPollError = "last_poll_error"
    }
}

/// Reports that a refresh was accepted; `count` is present only when it
/// completed synchronously.
struct RefreshResult: Decodable, Sendable {
    let accepted: Bool
    let count: Int?
}

/// The module store sizes around a cleanup.
struct ClearResult: Decodable, Sendable {
    let cleared: Bool
    let memory: String?
    let before: Int
    let after: Int
}

/// A successful send, and how many segments it took.
struct SendResult: Decodable, Sendable {
    let sent: Bool
    let segments: Int
}

/// Mirrors `GET /api/health`.
struct Health: Codable, Sendable {
    let ok: Bool
    let demo: Bool
    let port: String
    let esimAvailable: Bool
    let discoveryError: String

    enum CodingKeys: String, CodingKey {
        case ok
        case demo
        case port
        case esimAvailable = "esim_available"
        case discoveryError = "discovery_error"
    }
}

/// The core reports one of two shapes: a full status when an AT channel
/// answered, or what little is known from the USB inventory when none did.
enum StatusResult: Decodable, Sendable {
    case device(ModemStatus)
    case degraded(DegradedStatus)

    private enum CodingKeys: String, CodingKey {
        case kind, device, degraded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "device":
            self = .device(try container.decode(ModemStatus.self, forKey: .device))
        case "degraded":
            self = .degraded(try container.decode(DegradedStatus.self, forKey: .degraded))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "未知的状态类型 \(other)")
        }
    }
}

/// What the core can report with no AT channel available.
struct DegradedStatus: Decodable, Sendable {
    let operatorName: String
    let networkMode: String
    let simInserted: Bool
    let hardwareStatus: String
    let discoveryError: String

    enum CodingKeys: String, CodingKey {
        case operatorName = "operator"
        case networkMode = "network_mode"
        case simInserted = "sim_inserted"
        case hardwareStatus = "hardware_status"
        case discoveryError = "discovery_error"
    }
}

/// A full modem status, reported when an AT channel answered.
struct ModemStatus: Codable, Sendable {
    let imei: String
    let firmware: String
    let iccid: String
    let imsi: String
    let operatorName: String
    let simInserted: Bool
    let signalDBm: Int
    let signalRSRP: Int
    let signalRSRQ: Int
    let radioBand: String
    let regStatus: Int
    let regStatusText: String
    let psAttached: Bool
    let apn: String
    let networkMode: String
    let networkDuplex: String
    let usbnetMode: Int

    enum CodingKeys: String, CodingKey {
        case imei
        case firmware
        case iccid
        case imsi
        case operatorName = "operator"
        case simInserted = "sim_inserted"
        case signalDBm = "signal_dbm"
        case signalRSRP = "signal_rsrp"
        case signalRSRQ = "signal_rsrq"
        case radioBand = "radio_band"
        case regStatus = "reg_status"
        case regStatusText = "reg_status_text"
        case psAttached = "ps_attached"
        case apn
        case networkMode = "network_mode"
        case networkDuplex = "network_duplex"
        case usbnetMode = "usbnet_mode"
    }
}

extension ModemStatus {
    /// The four USB compositions the module's firmware accepts for
    /// `AT+QCFG="usbnet",N`.
    var usbnetModeLabel: String {
        switch usbnetMode {
        case 0: "短信模式（QMI）"
        case 1: "上网模式（ECM）"
        case 2: "实验模式 2"
        case 3: "实验模式 3"
        default: "未知"
        }
    }
}
