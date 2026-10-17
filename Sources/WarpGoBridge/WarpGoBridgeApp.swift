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
            BridgeSettingsContent(model: model)
                .frame(minWidth: 650, minHeight: 590)
        }
        .defaultSize(width: 700, height: 650)
        .windowResizability(.contentMinSize)
        .commands { BridgeSettingsCommands() }

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.phase == .ready ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .accessibilityLabel("Warp OpenCode Bridge: \(model.phase.title)")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct BridgeSettingsContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsView(model: model)
            .background(SettingsWindowRegistration())
            .onAppear {
                SettingsWindowPresenter.shared.configureOpenAction {
                    openWindow(id: "settings")
                }
                SettingsWindowPresenter.shared.show()
            }
    }
}

private struct BridgeSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                SettingsWindowPresenter.shared.show {
                    openWindow(id: "settings")
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
