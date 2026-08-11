import SwiftUI

@main
struct DJOneHubApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("DJOneHub") {
            StatusView()
                .environmentObject(model)
                .task {
                    delegate.model = model
                    await model.start()
                }
        }
    }
}

/// The core runs as a child process, so it has to be torn down explicitly;
/// otherwise it outlives the app and keeps holding the USB interface.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.stop()
        }
    }
}
