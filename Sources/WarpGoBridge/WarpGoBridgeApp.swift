import SwiftUI

@main
struct WarpGoBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        BridgeAppDelegate.model = model
    }

    var body: some Scene {
        Window("Warp OpenCode Bridge", id: "settings") {
            SettingsView(model: model)
                .frame(minWidth: 650, minHeight: 590)
        }
        .defaultSize(width: 700, height: 650)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.phase == .ready ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .accessibilityLabel("Warp OpenCode Bridge: \(model.phase.title)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 700, height: 650)
        }
    }
}
