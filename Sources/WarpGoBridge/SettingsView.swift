import SwiftUI
import BridgeCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState<String> private var selection = "setup"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Warp OpenCode Bridge")
                        .font(.title2.weight(.semibold))
                    Text("Your Go subscription, connected to Warp.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.phase.title, systemImage: model.phase.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(model.phase.color)
            }
            .padding(24)
            Divider()
            TabView(selection: $selection) {
                SetupView(model: model)
                    .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
                    .tag("setup")
                ConnectionView(model: model)
                    .tabItem { Label("Connection", systemImage: "network") }
                    .tag("connection")
                DiagnosticsView(model: model)
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                    .tag("diagnostics")
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Bridge could not complete this action", isPresented: Binding(
            get: { model.presentError },
            set: { model.presentError = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.latestError ?? "An unknown error occurred.")
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Bridge connection").font(.headline)
                            Text(model.phase == .ready ? "The proxy and tunnel are running." : "Turn on the bridge before using its model in Warp.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { model.phase == .ready || model.phase == .connecting },
                            set: { $0 ? model.start() : model.stop() }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.isConfigured || (model.isBusy && model.phase != .connecting))
                    }
                    .padding(8)
                }

                GroupBox("Conversation sessions") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Routing", selection: $model.sessionMode) {
                            Text("Automatic — conversation metadata or message history").tag(SessionMode.automatic)
                            Text("Strict — require conversation metadata").tag(SessionMode.strict)
                            Text("Manual — one conversation at a time").tag(SessionMode.manual)
                        }
                        .pickerStyle(.menu)
                        .disabled(model.isBusy || model.phase == .ready || model.phase == .connecting)
                        Text(model.sessionModeExplanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if model.sessionMode == .manual {
                            HStack {
                                Text("Session: \(model.manualSessionDisplay)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("New session") { model.newSession() }.disabled(model.isBusy)
                            }
                        }
                        if model.sessionMode == .automatic {
                            HStack {
                                Text("Resetting history requires new Warp chats.").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset routing history") { model.resetHistory() }.disabled(model.isBusy)
                            }
                        }
                        Text("Off/On preserves routing history while the app runs. After quitting/reopening the app or changing routing mode, start a new Warp chat if Warp does not send a conversation ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("What the switch controls") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("On starts the local proxy and its public Cloudflare Tunnel.", systemImage: "power")
                        Label("Off stops both. Select another model in Warp to continue without Go.", systemImage: "pause.circle")
                        Label("Keep this Mac awake and online while the bridge is in use.", systemImage: "laptopcomputer")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                if let error = model.latestError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection diagnostics").font(.headline)
                    Text("Request counts and session-routing events. Prompts and API keys are never logged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshDiagnostics() }
            }
            HStack(spacing: 12) {
                diagnosticCard("Proxy", value: model.proxyStatus, symbol: "server.rack")
                diagnosticCard("Tunnel", value: model.tunnelStatus, symbol: "network")
                diagnosticCard("Events", value: model.eventCount, symbol: "list.bullet.rectangle")
            }
            ScrollView {
                Text(model.diagnosticsText.isEmpty ? "No events yet. Set up the bridge, turn it on, then send a request from Warp." : model.diagnosticsText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy diagnostics", systemImage: "doc.on.doc") { model.copy(model.diagnosticsText) }
                Spacer()
                Button("Open app data folder", systemImage: "folder") { model.openDataFolder() }
            }
            Text("A running tunnel does not confirm that OpenCode accepted a model request. Check the result of your first Warp conversation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func diagnosticCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
