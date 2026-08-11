import Foundation

/// Finds the DJOneHub core binary.
enum CoreLocator {
    /// Search order:
    ///
    /// 1. bundled inside the app, which is how a shipped build ships it;
    /// 2. `DJONEHUB_CORE`, for pointing at an arbitrary build during development;
    /// 3. a DJOneHub checkout sitting next to this one, which is the usual
    ///    layout since the two are separate repositories.
    static func find() -> URL? {
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
}
