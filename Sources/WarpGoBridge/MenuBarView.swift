import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warp OpenCode Bridge").font(.headline)
                    Label(model.phase.title, systemImage: model.phase.symbol)
                        .font(.caption)
                        .foregroundStyle(model.phase.color)
                }
                Spacer()
            }

            if model.isConfigured {
                Toggle("Bridge enabled", isOn: Binding(
                    get: { model.phase == .ready || model.phase == .connecting },
                    set: { $0 ? model.start() : model.stop() }
                ))
                .toggleStyle(.switch)
                .disabled(model.isBusy && model.phase != .connecting)
                .accessibilityHint("Starts or stops the local proxy and Cloudflare Tunnel")

                if !model.endpointURL.isEmpty {
                    Text(model.endpointURL)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                if model.sessionMode == .manual {
                    HStack {
                        Label("Single conversation", systemImage: "bubble.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("New session") { model.newSession() }
                            .controlSize(.small)
                            .disabled(model.isBusy)
                    }
                }
            } else {
                Text("Connect Cloudflare and add your Go key to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Set up bridge…") { showSettings() }
                    .buttonStyle(.borderedProminent)
            }

            if let error = model.latestError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
            Divider()
            HStack {
                Button("Settings…") { showSettings() }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(18)
        .frame(width: 340)
    }

    private func showSettings() {
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
