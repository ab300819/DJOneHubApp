import XCTest

@testable import DJOneHub

/// A core that starts but never answers used to leave the window on "正在启动"
/// forever: the readiness check gave up only between attempts, and the one
/// attempt in flight never returned.
final class StartupTimeoutTests: XCTestCase {
    func testASilentCoreFailsStartupInsteadOfHanging() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-core-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let transport = StdioTransport(executable: script, demo: false)
        try transport.start()
        defer { transport.stop() }

        let started = Date()
        do {
            _ = try await transport.waitUntilReady(timeout: 1)
            XCTFail("a core that never answers must not count as ready")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "超时后应当立刻放弃，而不是等那次调用返回")
        }
    }
}
