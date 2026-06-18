import Foundation
import ServiceManagement

/// Registers the app as a login item so it relaunches at login (the always-on menu-bar
/// presence; no LaunchAgent daemon in the lean design). Only meaningful from the bundled .app.
public enum LoginItem {
    public static func register() {
        try? SMAppService.mainApp.register()
    }

    public static func unregister() {
        try? SMAppService.mainApp.unregister()
    }

    public static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
