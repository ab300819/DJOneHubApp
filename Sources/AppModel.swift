import Foundation
import Observation

/// Owns the transport's lifetime and the polled modem state.
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var health: Health?
    private(set) var status: StatusResult?
    private(set) var lastError: String?

    /// Exposed as the protocol rather than the concrete type so pages keep
    /// depending only on the seam an iPad build would reimplement.
    private(set) var transport: (any ModemTransport)?

    @ObservationIgnored private var core: StdioTransport?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Set `DJONEHUB_DEMO=1` to run the core against simulated data, which is
    /// how the UI can be developed without the module attached.
    private var demoRequested: Bool {
        ProcessInfo.processInfo.environment["DJONEHUB_DEMO"] == "1"
    }

    func start() async {
        guard let executable = CoreLocator.find() else {
            phase = .failed("找不到 djonehub-macos 核心程序。开发时可设置 DJONEHUB_CORE 指向它。")
            return
        }
        do {
            let transport = StdioTransport(executable: executable, demo: demoRequested)
            try transport.start()
            core = transport
            self.transport = transport

            health = try await transport.waitUntilReady()
            phase = .ready
            startPolling()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        core?.stop()
        core = nil
        // Cleared so a page that outlives the core fails with a clear "not
        // running" state rather than calling into a dead pipe.
        transport = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard let transport else { return }
        do {
            status = try await transport.status()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
