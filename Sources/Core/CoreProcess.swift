import Foundation

/// Runs the Go core as a child process on a private localhost port.
///
/// A port is reserved rather than hardcoded so the app never collides with a
/// `djonehub` the user started themselves on the default 7575.
@MainActor
final class CoreProcess {
    private let process = Process()
    private(set) var baseURL: URL

    /// Where to look for the core binary, in order:
    ///
    /// 1. bundled inside the app, which is how a shipped build ships it;
    /// 2. `DJONEHUB_CORE`, for pointing at an arbitrary build during development;
    /// 3. a DJOneHub checkout sitting next to this one, which is the usual
    ///    layout since the two are separate repositories.
    static func locateExecutable() -> URL? {
        if let bundled = Bundle.main.url(forResource: "djonehub-macos", withExtension: nil) {
            return bundled
        }
        if let override = ProcessInfo.processInfo.environment["DJONEHUB_CORE"] {
            return URL(fileURLWithPath: override)
        }
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // DJOneHubApp
            .deletingLastPathComponent()  // parent of both checkouts
            .appendingPathComponent("DJOneHub/dist/djonehub-macos")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    init(executable: URL, demo: Bool) throws {
        let port = try Self.reservePort()
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        process.executableURL = executable
        // -parent-pid lets the core exit on its own if this app dies without
        // getting to run its terminate handler, so it never leaks a process
        // still holding the module's USB interface.
        var args = [
            "-listen", "127.0.0.1:\(port)",
            "-parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        if demo { args.append("-demo") }
        process.arguments = args
    }

    func start() throws {
        try process.run()
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
    }

    var isRunning: Bool { process.isRunning }

    /// Asks the kernel for an unused port by binding to 0 and reading it back.
    private static func reservePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.coreUnavailable("无法创建套接字") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw TransportError.coreUnavailable("无法绑定端口") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw TransportError.coreUnavailable("无法读取端口") }
        return UInt16(bigEndian: assigned.sin_port)
    }
}
