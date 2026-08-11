import Foundation

/// Owns the core process lifetime and the polled modem state.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var health: Health?
    @Published private(set) var status: ModemStatus?
    @Published private(set) var lastError: String?

    private var core: CoreProcess?
    private var transport: ModemTransport?
    private var pollTask: Task<Void, Never>?

    /// Set `DJONEHUB_DEMO=1` to run the core against simulated data, which is
    /// how the UI can be developed without the module attached.
    private var demoRequested: Bool {
        ProcessInfo.processInfo.environment["DJONEHUB_DEMO"] == "1"
    }

    func start() async {
        guard let executable = CoreProcess.locateExecutable() else {
            phase = .failed("找不到 djonehub-macos 核心程序。开发时可设置 DJONEHUB_CORE 指向它。")
            return
        }
        do {
            let core = try CoreProcess(executable: executable, demo: demoRequested)
            try core.start()
            let transport = HTTPTransport(baseURL: core.baseURL)
            self.core = core
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
