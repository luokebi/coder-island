import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at login"
/// toggle. We use the modern API (macOS 13+) — the app's deployment
/// target is 14.0 so this is always available.
///
/// Notes:
/// - `register()` requires the app to live in a location launchd can
///   reach (e.g. /Applications). Running directly out of DerivedData
///   may fail with "Operation not permitted"; we surface that as a
///   `false` return so the SwiftUI toggle can roll back.
/// - macOS itself caches the registration. If the user toggles the
///   item off in System Settings → General → Login Items, our cached
///   `@AppStorage("launchAtLogin")` value will be wrong on next launch.
///   `currentlyEnabled()` lets the app sync from the system source of
///   truth at startup.
enum LoginItemHelper {
    static func currentlyEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success, false if the system rejected the
    /// register/unregister call.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            debugLog("[LoginItem] \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
