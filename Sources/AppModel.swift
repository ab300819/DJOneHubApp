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

    /// The most recent progress the core reported, or nil when nothing is
    /// running. Held here rather than in the page because AsyncStream takes a
    /// single consumer: a view that iterates it would start a second iteration
    /// every time it came back on screen.
    private(set) var downloadProgress: DownloadProgress?

    struct DownloadProgress: Equatable, Sendable {
        var percent: Int
        var message: String
    }

    @ObservationIgnored private var core: StdioTransport?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

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
            startListeningForEvents(on: transport)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel()
        eventTask = nil
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

    private func startListeningForEvents(on transport: StdioTransport) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self else { return }
                switch event.event {
                case CoreEventName.esimDownloadProgress:
                    downloadProgress = DownloadProgress(
                        percent: event.percent ?? 0, message: event.message ?? "")
                default:
                    break
                }
            }
        }
    }

    /// Called when an operation that reports progress finishes, so a completed
    /// bar does not linger over the next screen.
    func clearDownloadProgress() {
        downloadProgress = nil
    }

    /// The attached module's IMEI, when a full status has been read. The eSIM
    /// download needs it and the user should not have to look it up.
    var moduleIMEI: String? {
        guard case let .device(status) = status, !status.imei.isEmpty else { return nil }
        return status.imei
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
