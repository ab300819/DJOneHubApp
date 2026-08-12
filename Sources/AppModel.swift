import Foundation

/// Owns the transport's lifetime and the polled modem state.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var health: Health?
    @Published private(set) var status: StatusResult?
    @Published private(set) var lastError: String?

    /// Exposed as the protocol rather than the concrete type so pages keep
    /// depending only on the seam an iPad build would reimplement.
    private(set) var transport: (any ModemTransport)?

    private var core: StdioTransport?
    private var pollTask: Task<Void, Never>?

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
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
