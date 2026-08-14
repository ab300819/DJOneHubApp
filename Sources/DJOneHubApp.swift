import SwiftUI

@main
struct DJOneHubApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("DJOneHub") {
            RootView()
                .environment(model)
                .task {
                    delegate.model = model
                    await model.start()
                }
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("刷新模块状态") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
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
