import XCTest

@testable import DJOneHub

/// Decodes answers captured from a real module against the app's own DTOs.
///
/// The Swift side hand-writes about forty structures mirroring Go's wire shape,
/// so nothing on this side notices when a `json` tag changes upstream. These
/// fixtures are the frozen shapes the app was verified against; they catch a
/// Swift-side edit that breaks one. Catching a *Go*-side change needs the
/// fixtures re-captured against a live module — see IT-014/IT-015.
///
/// That these assertions have teeth is checked separately, by injecting drift
/// into the DTOs and requiring a test to fail: `make mutation`.
///
/// @verifies AC-121, AC-122
/// @testcase IT-011, IT-012
final class ContractDecodeTests: XCTestCase {
    // MARK: - IT-011 每个类型对真实载荷解码成功

    func testDeviceAndHealthDecode() throws {
        _ = try decode(Health.self, from: "health")
        _ = try decode(StatusResult.self, from: "status")
    }

    func testSMSDecode() throws {
        _ = try decode([ReceivedSMS].self, from: "sms.list")
        _ = try decode(SMSStatus.self, from: "sms.status")
    }

    func testNetworkDecode() throws {
        _ = try decode(TrafficSnapshot.self, from: "network.traffic")
        _ = try decode(LocalConnection.self, from: "network.local")
        _ = try decode(ActivitySnapshot.self, from: "network.activity")
        _ = try decode(NetworkDiagnostic.self, from: "network.diagnostic")
        _ = try decode(NetworkCheckResult.self, from: "network.check4g")
    }

    func testESIMDecode() throws {
        _ = try decode(ESIMOverviewResult.self, from: "esim.overview")
        _ = try decode(ESIMHealthResult.self, from: "esim.health")
        _ = try decode(ESIMSwitchResult.self, from: "esim.switch")
        _ = try decode(ESIMActionResult.self, from: "esim.rename")
    }

    func testModuleNotesDecode() throws {
        _ = try decode(ModuleNotes.self, from: "esim.moduleNotes.list")
        _ = try decode(ModuleNoteResult.self, from: "esim.moduleNotes.save")
        _ = try decode(ModuleNoteResult.self, from: "esim.moduleNotes.delete")
        _ = try decode(PhonebookProbe.self, from: "esim.phonebookProbe")
    }

    func testEventDecode() throws {
        _ = try decode(CoreEvent.self, from: "event")
    }

    // MARK: - IT-012 取值断言

    // Decoding alone cannot vouch for an optional field: a mistyped key decodes
    // to nil and the test still passes. These assert the value arrived.

    func testDiagnosticCarriesUSBDevice() throws {
        let device = try XCTUnwrap(decode(NetworkDiagnostic.self, from: "network.diagnostic").usbDevice)
        XCTAssertFalse(device.vendorID.isEmpty)
        XCTAssertFalse(device.productID.isEmpty)
        XCTAssertFalse(device.mode.isEmpty)
        // Six interfaces, four of them vendor-specific — the composition the
        // usbnet mode switch acts on.
        XCTAssertEqual(try XCTUnwrap(device.interfaces).count, 6)
    }

    func testDiagnosticCarriesHostInterfaces() throws {
        let diagnostic = try decode(NetworkDiagnostic.self, from: "network.diagnostic")
        XCTAssertFalse(try XCTUnwrap(diagnostic.hostInterfaces).isEmpty)
    }

    func testTrafficCarriesSampleClock() throws {
        // The core times the sample so the RPC round trip is not charged to the
        // interval a rate is derived over.
        XCTAssertGreaterThan(try decode(TrafficSnapshot.self, from: "network.traffic").sampledAtMS, 0)
    }

    func testModuleNotesCarriesCapacity() throws {
        let notes = try decode(ModuleNotes.self, from: "esim.moduleNotes.list")
        XCTAssertGreaterThan(notes.total, 0)
        // An empty phonebook must still arrive as a dictionary, not as nil.
        XCTAssertNotNil(notes.notes)
    }

    func testModuleNoteSaveCarriesIndex() throws {
        let result = try decode(ModuleNoteResult.self, from: "esim.moduleNotes.save")
        XCTAssertNotNil(result.index)
        XCTAssertFalse(result.message.isEmpty)
    }

    func testPhonebookProbeCarriesResponses() throws {
        let probe = try decode(PhonebookProbe.self, from: "esim.phonebookProbe")
        XCTAssertFalse(try XCTUnwrap(probe.responses).isEmpty)
        XCTAssertFalse(probe.storageStatus.isEmpty)
        XCTAssertTrue(probe.portable)
    }

    // MARK: - AC-122 方法可以合法地答 null

    func testAbsentPayloadIsNotADecodingFailure() throws {
        XCTAssertTrue(CoreJSON.isAbsent(Data("null".utf8)))
        XCTAssertTrue(CoreJSON.isAbsent(Data()))
        XCTAssertFalse(CoreJSON.isAbsent(try fixtureData("network.local")))
    }

    // MARK: - 载荷读取

    private func decode<T: Decodable>(
        _ type: T.Type, from name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> T {
        try CoreJSON.decoder.decode(type, from: try fixtureData(name, file: file, line: line))
    }

    private func fixtureData(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url, "找不到载荷 \(name).json", file: file, line: line))
    }
}
