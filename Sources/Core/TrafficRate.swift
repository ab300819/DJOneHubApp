import Foundation

/// One reading of an interface's cumulative byte counters.
struct TrafficSample: Equatable, Sendable {
    let interface: String
    let rx: UInt64
    let tx: UInt64
    /// Stamped by the core, so the RPC round trip is not charged to the
    /// interval a rate is derived over.
    let atMS: Int64
}

/// Bytes per second in each direction.
struct TrafficRate: Equatable, Sendable {
    let rxPerSecond: Double
    let txPerSecond: Double
}

/// Turns two counter readings into a rate.
///
/// The core reports cumulative counters, so a rate only exists between two
/// samples. Several situations make the difference meaningless rather than
/// merely small, and each has to answer "no rate yet" instead of a number that
/// looks plausible: no earlier sample, a different interface, and an interval
/// too short to divide by.
///
/// The fourth is not cosmetic. A module that re-enumerates restarts its
/// counters, and subtracting the larger previous reading from it traps on
/// unsigned underflow — so that guard is what stands between a replugged
/// module and a crash.
enum TrafficRateDerivation {
    /// The shortest interval a rate is derived over. Below this the division
    /// amplifies the sampling jitter more than it measures traffic.
    static let minimumInterval: TimeInterval = 0.5

    /// Returns the sample to remember and the rate to show. A nil sample means
    /// there is nothing to compare the next reading against.
    static func derive(from snapshot: TrafficSnapshot?, previous: TrafficSample?)
        -> (sample: TrafficSample?, rate: TrafficRate?)
    {
        guard let snapshot, snapshot.available, let interface = snapshot.interface else {
            return (nil, nil)
        }
        let sample = TrafficSample(
            interface: interface, rx: snapshot.rxBytes, tx: snapshot.txBytes,
            atMS: snapshot.sampledAtMS)
        guard let previous, previous.interface == interface else {
            return (sample, nil)
        }
        let elapsed = Double(sample.atMS - previous.atMS) / 1000
        guard elapsed >= minimumInterval, sample.rx >= previous.rx, sample.tx >= previous.tx else {
            return (sample, nil)
        }
        return (
            sample,
            TrafficRate(
                rxPerSecond: Double(sample.rx - previous.rx) / elapsed,
                txPerSecond: Double(sample.tx - previous.tx) / elapsed)
        )
    }
}
