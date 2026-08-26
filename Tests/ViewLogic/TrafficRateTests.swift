import XCTest

@testable import DJOneHub

/// The core reports cumulative counters, so a rate only exists between two
/// samples. What matters is not the arithmetic but the four situations where
/// the difference is meaningless rather than merely small — each has to answer
/// "no rate yet" instead of a number that looks plausible on screen.
///
/// AC-049 是核心侧定的规则；App 独立推导瞬时速率，所以这条不变量两侧各自成立，
/// 各自有测试（Go 侧见 UT-022 等）。
///
/// @verifies AC-049
/// @testcase UT-048
final class TrafficRateTests: XCTestCase {
    private func snapshot(
        interface: String? = "en11", available: Bool = true,
        rx: UInt64 = 0, tx: UInt64 = 0, atMS: Int64 = 0
    ) -> TrafficSnapshot {
        let json = """
            {"available":\(available),\(interface.map { "\"interface\":\"\($0)\"," } ?? "")
             "rx_bytes":\(rx),"tx_bytes":\(tx),"sampled_at_ms":\(atMS),
             "session_rx_bytes":0,"session_tx_bytes":0,"session_total_bytes":0}
            """
        return try! CoreJSON.decoder.decode(TrafficSnapshot.self, from: Data(json.utf8))
    }

    private let earlier = TrafficSample(interface: "en11", rx: 1_000, tx: 2_000, atMS: 10_000)

    func testRateIsBytesPerSecondBetweenTwoSamples() {
        let (sample, rate) = TrafficRateDerivation.derive(
            from: snapshot(rx: 3_000, tx: 2_500, atMS: 12_000), previous: earlier)

        XCTAssertEqual(sample, TrafficSample(interface: "en11", rx: 3_000, tx: 2_500, atMS: 12_000))
        // 2000 bytes over 2 seconds, 500 over the same.
        XCTAssertEqual(try XCTUnwrap(rate).rxPerSecond, 1_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rate).txPerSecond, 250, accuracy: 0.001)
    }

    /// The first reading has nothing to subtract from. It still has to be
    /// remembered, or a rate never appears at all.
    func testFirstSampleYieldsNoRateButIsRemembered() {
        let (sample, rate) = TrafficRateDerivation.derive(
            from: snapshot(rx: 3_000, tx: 2_500, atMS: 12_000), previous: nil)

        XCTAssertNotNil(sample)
        XCTAssertNil(rate)
    }

    /// Subtracting one interface's counters from another's produces a number
    /// with no meaning, and switching usbnet mode changes which interface is
    /// read.
    func testInterfaceChangeDiscardsTheRate() {
        let (sample, rate) = TrafficRateDerivation.derive(
            from: snapshot(interface: "en12", rx: 3_000, tx: 2_500, atMS: 12_000),
            previous: earlier)

        XCTAssertEqual(sample?.interface, "en12")
        XCTAssertNil(rate)
    }

    /// A re-enumerated module restarts its counters. Without this guard the
    /// unsigned subtraction traps and takes the app down — measured, not
    /// assumed: removing it crashes this test run rather than failing it.
    func testCounterRollbackDiscardsTheRate() {
        for (rx, tx) in [(UInt64(500), UInt64(2_500)), (3_000, 1_500)] {
            let (sample, rate) = TrafficRateDerivation.derive(
                from: snapshot(rx: rx, tx: tx, atMS: 12_000), previous: earlier)

            XCTAssertNotNil(sample, "the new counters must still become the baseline")
            XCTAssertNil(rate, "rx=\(rx) tx=\(tx) went backwards but produced a rate")
        }
    }

    /// Dividing by a near-zero interval amplifies sampling jitter far more than
    /// it measures traffic.
    func testTooShortAnIntervalDiscardsTheRate() {
        let (_, rate) = TrafficRateDerivation.derive(
            from: snapshot(rx: 3_000, tx: 2_500, atMS: 10_400), previous: earlier)

        XCTAssertNil(rate)
    }

    func testTheMinimumIntervalItselfProducesARate() {
        let boundary = earlier.atMS + Int64(TrafficRateDerivation.minimumInterval * 1000)
        let (_, rate) = TrafficRateDerivation.derive(
            from: snapshot(rx: 1_500, tx: 2_000, atMS: boundary), previous: earlier)

        XCTAssertEqual(try XCTUnwrap(rate).rxPerSecond, 1_000, accuracy: 0.001)
    }

    /// An unavailable reading must also clear the baseline: keeping it would
    /// let the next reading be divided by an interval spanning the outage.
    func testUnavailableSnapshotClearsTheBaseline() {
        for unavailable in [snapshot(available: false), snapshot(interface: nil)] {
            let (sample, rate) = TrafficRateDerivation.derive(from: unavailable, previous: earlier)

            XCTAssertNil(sample)
            XCTAssertNil(rate)
        }
        let (sample, rate) = TrafficRateDerivation.derive(from: nil, previous: earlier)
        XCTAssertNil(sample)
        XCTAssertNil(rate)
    }
}
