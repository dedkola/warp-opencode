import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ViewState<Bool> private var showRelayToken = false
    @ViewState<String?> private var copiedField: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                setupSection(number: 1, title: "Connect Cloudflare", complete: model.cloudflareAuthorized) {
                    Text("Sign in with Cloudflare in your browser and authorize a domain already active on your account.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(model.helperStatus, systemImage: model.helperAvailable ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(model.helperAvailable ? .secondary : .primary)
                        Spacer()
                        if !model.helperAvailable {
                            Button("Choose cloudflared…") { model.chooseHelper() }
                                .disabled(model.isBusy)
                        }
                    }
                    .font(.callout)
                    HStack {
                        Button(model.cloudflareAuthorized ? "Reconnect Cloudflare…" : "Connect Cloudflare…") {
                            model.loginCloudflare()
                        }
                        .disabled(!model.helperAvailable || model.isBusy || model.phase == .ready)
                        if model.cloudflareAuthorized {
                            Label("Authorized", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                    }
                    if model.isAuthorizing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Complete domain authorization in your browser…").font(.callout)
                            Spacer()
                            Button("Cancel") { model.cancelOperation() }
                        }
                    }
                    if !model.helperAvailable {
                        Text("Packaged releases include the Cloudflare tunnel helper. For a development build, choose your cloudflared executable or run scripts/fetch-cloudflared.sh first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.cloudflareAuthorized {
                        LabeledContent("Domain") {
                            TextField("example.com", text: $model.domain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                                .disabled(model.isBusy || model.phase == .ready)
                        }
                        Text("Use the domain you authorized in Cloudflare. This installation manages one tunnel and one authorized domain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                setupSection(number: 2, title: "Configure your bridge", complete: model.isConfigured) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Address").frame(width: 90, alignment: .leading)
                        TextField("warp-go", text: $model.subdomain)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .disabled(model.isBusy || model.phase == .ready)
                        Text(".\(model.domain.isEmpty ? "yourdomain.com" : model.domain)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Go API key").frame(width: 90, alignment: .leading)
                        SecureField(model.hasSavedGoKey ? "Saved in Keychain — enter to replace" : "Paste your OpenCode Go key", text: $model.goAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isBusy || model.phase == .ready)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Model IDs").frame(width: 90, alignment: .leading)
                        TextField("deepseek-v4.1-flash", text: $model.modelID)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isBusy || model.phase == .ready)
                    }
                    Text("Use exact Go model IDs, separated by commas for multiple models. Your key stays in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(model.isConfigured ? "Save changes" : "Create bridge") { model.prepareConnection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canPrepare || model.isBusy || model.phase == .ready)
                        if model.isBusy && !model.isAuthorizing {
                            ProgressView().controlSize(.small)
                            Text(model.operationStatus).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Text("Creates a tunnel and DNS record on your chosen Cloudflare domain. An existing unrelated DNS record is never overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.isConfigured {
                    setupSection(number: 3, title: "Connect Warp", complete: false) {
                        Text("Add a custom OpenAI-compatible provider in Warp. Copy these settings once, then select your Go model.")
                            .foregroundStyle(.secondary)
                        copyRow("Endpoint URL", value: model.endpointURL)
                        HStack(spacing: 8) {
                            Text("API key").frame(width: 90, alignment: .leading)
                            Text(showRelayToken ? model.relayToken : String(repeating: "•", count: 24))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button(showRelayToken ? "Hide" : "Show") { showRelayToken.toggle() }
                                .buttonStyle(.borderless)
                            copyButton("API key", value: model.relayToken)
                        }
                        ForEach(Array(model.configuredModels.enumerated()), id: \.offset) { _, modelID in
                            copyRow("Model ID", value: modelID)
                        }
                        Text("This API key is the private bridge token. Keep your OpenCode Go key in this app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Warp") { model.openWarp() }
                            Link("Warp setup guide ↗", destination: URL(string: "https://docs.warp.dev/agents/inference/custom-inference-endpoint")!)
                            Spacer()
                            Button(model.phase == .ready ? "Test connection" : "Turn on & test") {
                                model.testConnection()
                            }
                            .disabled(model.isBusy)
                        }
                        if !model.connectionTestStatus.isEmpty {
                            Label(model.connectionTestStatus, systemImage: model.connectionTestSucceeded ? "checkmark.circle" : "info.circle")
                                .font(.callout)
                                .foregroundStyle(model.connectionTestSucceeded ? .green : .secondary)
                        }
                        Text("The connection test checks tunnel reachability and bridge authentication. It does not send a paid model request. Send a short prompt from Warp to finish verification.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.latestError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
        }
    }

    private func setupSection<Content: View>(number: Int, title: String, complete: Bool, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(complete ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.1))
                        if complete {
                            Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        } else {
                            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .frame(width: 25, height: 25)
                    Text(title).font(.headline)
                }
                content()
                    .font(.callout)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 90, alignment: .leading)
            Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
            copyButton(title, value: value)
        }
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button {
            model.copy(value)
            copiedField = title
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedField == title { copiedField = nil }
            }
        } label: {
            Image(systemName: copiedField == title ? "checkmark" : "doc.on.doc")
        }
        .help("Copy \(title)")
        .accessibilityLabel("Copy \(title)")
    }
}
