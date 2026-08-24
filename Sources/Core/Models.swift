import Foundation

/// One message read from the module.
struct ReceivedSMS: Decodable, Sendable, Identifiable {
    let sender: String
    let content: String
    let code: String?
    let timestamp: Date

    /// The core assigns no message identifier, so identity is the full triple
    /// that distinguishes one message from another. Hashing the content would
    /// be shorter but `hashValue` is seeded per process and is not meant to
    /// carry identity; two messages that only differ past a collision would
    /// then render as one row.
    var id: String { "\(timestamp.timeIntervalSince1970)|\(sender)|\(content)" }
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

// MARK: - Network

/// Mirrors `network.traffic`. `available` is false when the module has no
/// interface up, in which case the counters mean nothing and are not shown.
struct TrafficSnapshot: Decodable, Sendable {
    let available: Bool
    let interface: String?
    let rxBytes: UInt64
    let txBytes: UInt64
    let sessionRX: UInt64
    let sessionTX: UInt64
    let sessionTotal: UInt64
    /// When the core read the counters. A rate derived from the app's own clock
    /// would charge the round trip to the elapsed time; this is the moment the
    /// numbers actually describe.
    let sampledAtMS: Int64
    let error: String?

    enum CodingKeys: String, CodingKey {
        case available, interface, error
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case sessionRX = "session_rx_bytes"
        case sessionTX = "session_tx_bytes"
        case sessionTotal = "session_total_bytes"
        case sampledAtMS = "sampled_at_ms"
    }
}

/// The module's own interface as the host sees it.
struct LocalConnection: Decodable, Sendable {
    let interface: String
    let ipv4: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case interface, ipv4
        case isDefault = "is_default"
    }
}

/// One flow riding the module's path, as sampled from the host.
struct ActivityRecord: Decodable, Sendable, Identifiable {
    let process: String
    let host: String?
    let ip: String
    let port: String?
    let protocolName: String
    let interface: String
    let state: String?
    let rxBytes: UInt64
    let txBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case process, host, ip, port, interface, state
        case protocolName = "protocol"
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
    }

    /// The sampler names no flow, so identity is what distinguishes one row
    /// from another on screen.
    var id: String { "\(process)|\(protocolName)|\(ip)|\(port ?? "")|\(interface)" }

    /// What to show for the remote end: a resolved name when there is one, the
    /// address otherwise.
    var remote: String {
        let name = (host?.isEmpty == false) ? host! : ip
        guard let port, !port.isEmpty else { return name }
        return "\(name):\(port)"
    }
}

/// Mirrors `network.activity`. With a tunnel up the flows are reported on the
/// tunnel rather than on the module's own interface, so both are named.
struct ActivitySnapshot: Decodable, Sendable {
    let available: Bool
    let physicalInterface: String?
    let physicalIPv4: String?
    let tunnelInterface: String?
    let physicalActive: Bool
    /// Null rather than empty when nothing is on the wire, which is how Go
    /// renders a nil slice.
    let connections: [ActivityRecord]?

    enum CodingKeys: String, CodingKey {
        case available, connections
        case physicalInterface = "physical_interface"
        case physicalIPv4 = "physical_ipv4"
        case tunnelInterface = "tunnel_interface"
        case physicalActive = "physical_active"
    }
}

/// The verdict of a routing or proxy check.
struct NetworkCheckResult: Decodable, Sendable {
    let ok: Bool
    let summary: String
    let detail: String
}

/// One of the module's packet data contexts.
struct PDPContext: Decodable, Sendable, Identifiable {
    let id: Int
    let pdn: String
    let apn: String
}

/// A host network interface.
struct HostInterface: Decodable, Sendable, Identifiable {
    let name: String
    let status: String
    let ipv4: String
    let kind: String

    var id: String { name }
}

/// Where the host currently sends traffic.
struct DefaultRoute: Decodable, Sendable {
    let interface: String
    let gateway: String
}

/// Mirrors `network.diagnostic`: the module's data configuration alongside what
/// the host has to show for it.
struct NetworkDiagnostic: Decodable, Sendable {
    let usbnetMode: String
    let usbcfg: String
    let pdpContexts: [PDPContext]?
    let activeContexts: [Int]?
    let pdpAddresses: [String]?
    let hostInterfaces: [HostInterface]?
    let defaultRoute: DefaultRoute
    let usbNetworkPresent: Bool
    let usbDevice: USBDevice?
    let errors: [String: String]?

    enum CodingKeys: String, CodingKey {
        case usbcfg, errors
        case usbnetMode = "usbnet_mode"
        case pdpContexts = "pdp_contexts"
        case activeContexts = "active_contexts"
        case pdpAddresses = "pdp_addresses"
        case hostInterfaces = "mac_interfaces"
        case defaultRoute = "default_route"
        case usbNetworkPresent = "usb_network_present"
        case usbDevice = "usb_device"
    }
}

/// The module as the USB bus describes it. Carried by the diagnostic rather
/// than the status, because the status only reports it in the degraded shape —
/// the reading that is available exactly when the AT channel is not.
struct USBDevice: Decodable, Sendable {
    let product: String
    let vendor: String
    let vendorID: String
    let productID: String
    let locationID: String
    let speed: String
    let mode: String
    let interfaces: [USBInterface]?

    enum CodingKeys: String, CodingKey {
        case product, vendor, speed, mode, interfaces
        case vendorID = "vendor_id"
        case productID = "product_id"
        case locationID = "location_id"
    }

    /// The pair that decides whether the host will talk to the module at all.
    var identifier: String { "\(vendorID):\(productID)" }
}

/// One interface of the module's current USB composition. Which of these are
/// present is what a usbnet mode change actually alters.
struct USBInterface: Decodable, Sendable, Identifiable {
    let number: Int
    let interfaceClass: Int
    let subclass: Int
    let protocolNumber: Int
    let endpoints: Int

    enum CodingKeys: String, CodingKey {
        case number, subclass, endpoints
        case interfaceClass = "class"
        case protocolNumber = "protocol"
    }

    var id: Int { number }
}

/// An accepted USB composition change; it takes effect after a reboot.
struct USBNetResult: Decodable, Sendable {
    let mode: Int
    let response: String
    let needsReboot: Bool

    enum CodingKeys: String, CodingKey {
        case mode, response
        case needsReboot = "needs_reboot"
    }
}

/// An accepted module restart.
struct RebootResult: Decodable, Sendable {
    let accepted: Bool
    let response: String
}

// MARK: - eSIM

/// One profile installed on the card.
struct ESIMProfile: Decodable, Sendable, Identifiable {
    let iccid: String
    let name: String
    let serviceProviderName: String
    let state: Int
    let stateText: String

    enum CodingKeys: String, CodingKey {
        case iccid, name, state
        case serviceProviderName = "service_provider_name"
        case stateText = "state_text"
    }

    var id: String { iccid }

    /// State 1 is the enabled profile; the card allows exactly one.
    var isEnabled: Bool { state == 1 }
}

/// Profiles grouped by the eUICC application they live in. A card can host more
/// than one, and switching needs the AID as well as the ICCID.
struct ESIMProfileGroup: Decodable, Sendable, Identifiable {
    let aidHex: String
    let eid: String?
    let profiles: [ESIMProfile]?

    enum CodingKeys: String, CodingKey {
        case eid, profiles
        case aidHex = "aid_hex"
    }

    var id: String { aidHex }
}

/// What the card says about itself.
struct ESIMChipInfo: Decodable, Sendable {
    let skuName: String?
    let serialNumber: String?
    let firmware: String?

    enum CodingKeys: String, CodingKey {
        case skuName = "sku_name"
        case serialNumber = "serial_number"
        case firmware
    }
}

/// The card's contents. The core reports the same shape whether it read a real
/// card or served demo data, so one type covers both.
struct ESIMOverview: Decodable, Sendable {
    let chipInfo: ESIMChipInfo?
    let profiles: [ESIMProfileGroup]?

    enum CodingKeys: String, CodingKey {
        case chipInfo = "chip_info"
        case profiles
    }
}

/// Mirrors `esim.overview`. A physical SIM is not an error: the module simply
/// has no eUICC to enumerate.
struct ESIMOverviewResult: Decodable, Sendable {
    let physicalSIM: Bool
    let message: String?
    let overview: ESIMOverview?
    let demoPayload: ESIMOverview?

    enum CodingKeys: String, CodingKey {
        case physicalSIM = "physical_sim"
        case message, overview
        case demoPayload = "demo_payload"
    }

    /// Whichever of the two the core filled in.
    var card: ESIMOverview? { overview ?? demoPayload }
}

/// Mirrors `esim.health`: the enabled profile cross-checked against what the
/// module is actually registered on.
struct ESIMHealthResult: Decodable, Sendable {
    let physicalSIM: Bool
    let ok: Bool
    let message: String?
    let activeProfile: ESIMProfile?
    let moduleICCID: String?
    let operatorName: String?
    let registration: String?
    let registered: Bool

    enum CodingKeys: String, CodingKey {
        case ok, message, registration, registered
        case physicalSIM = "physical_sim"
        case activeProfile = "active_profile"
        case moduleICCID = "module_iccid"
        case operatorName = "operator"
    }
}

/// An accepted profile switch. The module restarts, so the app has to expect the
/// core's channel to go quiet for a moment afterwards.
struct ESIMSwitchResult: Decodable, Sendable {
    let demo: Bool
    let switchAccepted: Bool
    let phase: String?
    let targetICCID: String?
    let moduleRebootRequested: Bool
    let moduleRebootWarning: String?
    let reconnectWaitSeconds: Int

    enum CodingKeys: String, CodingKey {
        case demo, phase
        case switchAccepted = "switch_accepted"
        case targetICCID = "target_iccid"
        case moduleRebootRequested = "module_reboot_requested"
        case moduleRebootWarning = "module_reboot_warning"
        case reconnectWaitSeconds = "reconnect_wait_seconds"
    }
}

/// A completed download, delete or rename. All three report the same way.
struct ESIMActionResult: Decodable, Sendable {
    let demo: Bool
    let message: String?
}

// MARK: - Module phonebook

/// A note kept in the module's own phonebook, keyed to the profile's ICCID.
///
/// This is the one place where a note survives moving the card to another
/// machine: the module stores it, not the app. That is also what limits it —
/// the entry is a phonebook record, so the three fields have to fit in one.
struct ModuleProfileNote: Codable, Sendable, Identifiable {
    var index: Int = 0
    var iccid: String
    var label: String
    var phone: String
    var tags: String

    var id: String { iccid }

    /// All three fields blank is how a deletion is expressed on the wire, so
    /// the UI needs the same test to describe what a save will do.
    var isEmpty: Bool {
        [label, phone, tags].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// The module phonebook's contents and how full it is.
struct ModuleNotes: Decodable, Sendable {
    let notes: [String: ModuleProfileNote]?
    let used: Int
    let total: Int
}

/// A confirmed phonebook write. A deletion carries no index, since there is no
/// longer a record to point at.
struct ModuleNoteResult: Decodable, Sendable {
    let message: String
    let index: Int?
}

/// What the module says about its card-side phonebook, gathered by asking
/// rather than by writing: the probe issues only queries, so a module that
/// cannot do this is not left with a stray contact.
struct PhonebookProbe: Decodable, Sendable {
    let storageSupported: Bool
    let storageSelected: Bool
    let readSupported: Bool
    let writeSupported: Bool
    let storageStatus: String
    let responses: [String: String]?

    enum CodingKeys: String, CodingKey {
        case responses
        case storageSupported = "storage_supported"
        case storageSelected = "storage_selected"
        case readSupported = "read_supported"
        case writeSupported = "write_supported"
        case storageStatus = "storage_status"
    }

    /// Storage that is both present and selectable — without this, the rest of
    /// the answers describe nothing usable.
    var storageUsable: Bool { storageSupported && storageSelected }

    /// Whether notes written here would travel with the card.
    var portable: Bool { storageUsable && readSupported && writeSupported }
}
