import Foundation

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

/// Mirrors `GET /api/status`.
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
