import XCTest

@testable import DJOneHub

/// Small pieces of judgement the pages depend on. Each has branches, and each
/// was previously reachable only by looking at the screen.
///
/// @verifies AC-106, AC-114, AC-115
/// @testcase UT-049
final class PresentationTests: XCTestCase {
    private func probe(status: String, read: Bool = true, write: Bool = true,
                       supported: Bool = true, selected: Bool = true) -> PhonebookProbe {
        let json = """
            {"storage_supported":\(supported),"storage_selected":\(selected),
             "read_supported":\(read),"write_supported":\(write),
             "storage_status":\(String(data: try! JSONEncoder().encode(status), encoding: .utf8)!)}
            """
        return try! CoreJSON.decoder.decode(PhonebookProbe.self, from: Data(json.utf8))
    }

    // MARK: - 通讯录能力

    /// Notes are only worth writing to the module if they can be written, read
    /// back, and the storage is actually selectable. Any one missing and they
    /// would not travel with the card, which is the whole point of them.
    func testPortableRequiresAllFourCapabilities() {
        XCTAssertTrue(probe(status: "").portable)
        XCTAssertFalse(probe(status: "", read: false).portable, "unreadable notes are not portable")
        XCTAssertFalse(probe(status: "", write: false).portable, "unwritable notes are not portable")
        XCTAssertFalse(probe(status: "", supported: false).portable)
        XCTAssertFalse(probe(status: "", selected: false).portable)
    }

    /// The raw answer arrives with the echoed command and its terminator around
    /// it. Showing all of it would put an `OK` on screen next to a number.
    func testCapacityLineIsLiftedOutOfTheRawAnswer() {
        let raw = "AT+CPBS?\r\n+CPBS: \"SM\",0,500\r\nOK"

        XCTAssertEqual(probe(status: raw).capacityLine, "+CPBS: \"SM\",0,500")
    }

    /// An answer with no capacity line still shows that the module said
    /// something; swallowing it would look identical to no answer at all.
    func testAnAnswerWithoutACapacityLineIsShownAsIs() {
        XCTAssertEqual(probe(status: "ERROR").capacityLine, "ERROR")
        XCTAssertEqual(probe(status: "").capacityLine, "未返回容量信息")
    }

    // MARK: - 模块资料

    /// Clearing all three fields is how a note is deleted, so "empty" decides
    /// between a save and a delete. Whitespace has to count as empty or a stray
    /// space would silently keep a record the user meant to remove.
    func testANoteIsEmptyOnlyWhenAllThreeFieldsAre() {
        let blank = ModuleProfileNote(iccid: "8986", label: "", phone: "", tags: "")
        XCTAssertTrue(blank.isEmpty)
        XCTAssertTrue(ModuleProfileNote(iccid: "8986", label: " ", phone: "\t", tags: "\n").isEmpty)

        for note in [
            ModuleProfileNote(iccid: "8986", label: "主号", phone: "", tags: ""),
            ModuleProfileNote(iccid: "8986", label: "", phone: "13800138000", tags: ""),
            ModuleProfileNote(iccid: "8986", label: "", phone: "", tags: "常用"),
        ] {
            XCTAssertFalse(note.isEmpty, "a note carrying \(note) would be deleted")
        }
    }

    // MARK: - 短信状态摘要

    private func smsStatus(count: Int, stored: Int, autoCleanup: Bool = true,
                           polling: Bool = true, error: String = "") -> SMSStatus {
        let json = """
            {"count":\(count),"stored":\(stored),"polling":\(polling),"poll_interval_s":8,
             "auto_cleanup_me":\(autoCleanup),"last_poll_error":"\(error)"}
            """
        return try! CoreJSON.decoder.decode(SMSStatus.self, from: Data(json.utf8))
    }

    /// The list is capped and the archive is not, so reporting the list's own
    /// length as the total would present a cap as loss.
    func testTheSummarySaysWhenTheListIsShowingOnlyPartOfTheArchive() {
        XCTAssertTrue(smsStatus(count: 500, stored: 3_214).summary.contains("显示最近 500 条 · 共 3214 条"))
    }

    func testTheSummaryDropsTheQualifierWhenNothingIsHidden() {
        let summary = smsStatus(count: 12, stored: 12).summary
        XCTAssertTrue(summary.contains("共 12 条"))
        XCTAssertFalse(summary.contains("显示最近"), "没有内容被截断时不该出现「显示最近」")
    }

    /// Keeping the module's copy changes what a full module means later, so it
    /// has to be visible rather than inferable only from a launch argument.
    func testKeepingTheModuleCopyIsVisibleInTheSummary() {
        XCTAssertTrue(smsStatus(count: 1, stored: 1, autoCleanup: false).summary.contains("保留模块副本"))
        XCTAssertFalse(smsStatus(count: 1, stored: 1).summary.contains("保留模块副本"))
    }

    func testAPollErrorIsCarriedIntoTheSummary() {
        XCTAssertTrue(smsStatus(count: 0, stored: 0, error: "串口已断开").summary.contains("串口已断开"))
    }

    // MARK: - 字节读数

    /// Bytes are counted in binary multiples, and the unit has to climb or a
    /// gigabyte reads as ten digits.
    func testByteCountsClimbThroughBinaryUnits() {
        XCTAssertEqual(ByteCount.describe(0), "0 B")
        XCTAssertEqual(ByteCount.describe(1023), "1023 B")
        XCTAssertEqual(ByteCount.describe(1024), "1.00 KiB")
        XCTAssertEqual(ByteCount.describe(1024 * 1024), "1.00 MiB")
        XCTAssertEqual(ByteCount.describe(1024 * 1024 * 1024), "1.00 GiB")
    }

    /// Two decimals below ten and one above keeps the width steady while a
    /// number is changing every few seconds.
    func testPrecisionDropsOnceTheNumberIsWideEnough() {
        XCTAssertEqual(ByteCount.describe(9 * 1024), "9.00 KiB")
        XCTAssertEqual(ByteCount.describe(10 * 1024), "10.0 KiB")
    }

    /// Converting a negative Double to UInt64 traps, taking the app with it.
    /// Today's derivation cannot produce one — it refuses to subtract counters
    /// that went backwards — so this is what keeps a future caller that skips
    /// that guard from crashing rather than merely showing a wrong number.
    func testANegativeRateIsFlooredRatherThanTrapping() {
        XCTAssertEqual(ByteCount.describeRate(0), "0 B/s")
        XCTAssertEqual(ByteCount.describeRate(-0.4), "0 B/s")
        // Large enough that flooring and taking the magnitude differ: a guard
        // that mirrored instead of floored would report traffic that ran
        // backwards as traffic that ran fast.
        XCTAssertEqual(ByteCount.describeRate(-4096), "0 B/s")
        XCTAssertEqual(ByteCount.describeRate(2048), "2.00 KiB/s")
    }
}
