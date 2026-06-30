import AppKit
import CompanionKit
import SwiftUI

// Thin @main shell - menu-bar-only (LSUIElement, no Dock icon). State lives in CompanionKit's
// AppModel; the dropdown is a custom SwiftUI popover (PanelView) via .menuBarExtraStyle(.window).
@main
struct ClaudeCompanionApp: App {
    @State private var model: AppModel

    init() {
        let m = AppModel()
        m.start()
        _model = State(initialValue: m)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image("MenuBarIcon")            // VH template - tints with the menu bar
                    .opacity(model.autoAccept ? 1.0 : 0.4)   // dimmed when auto-accept is off
                Text(model.statusText)
                    .font(.system(size: 12))   // menu-bar default is too large; pin it small
            }
        }
        .menuBarExtraStyle(.window)

        // The deep surface: a single resizable, tabbed window opened from the popover. A plain
        // `Window` (not `WindowGroup`) so there's only ever one instance. The popover raises it via
        // openWindow(id:) + NSApp.activate (LSUIElement apps don't come forward on their own).
        Window("Claude Companion", id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
    }
}
