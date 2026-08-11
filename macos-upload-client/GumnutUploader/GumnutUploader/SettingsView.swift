import SwiftUI
import UploaderCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Draft of the key being typed; committed to the model (and Keychain)
    /// only on Save & Test, so the rest of the app never sees a partial key.
    @State private var apiKeyDraft = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Server") {
                TextField("Server URL", text: $model.serverURLString, prompt: Text(Store.defaultServerURL))
                    .autocorrectionDisabled()
                Picker("Library", selection: $model.selectedLibraryId) {
                    Text("Account default").tag(String?.none)
                    ForEach(model.libraries, id: \.id) { library in
                        Text(library.name).tag(Optional(library.id))
                    }
                }
                LabeledContent("") {
                    Button("Apply Server Settings") {
                        model.applyServerSettings()
                    }
                    .disabled(model.isRunning)
                }
                Text(
                    "Changing the server or library resets what this app believes is "
                        + "already synced (file hashes are kept). The next Analyze rebuilds it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("API key") {
                SecureField("API key", text: $apiKeyDraft, prompt: Text("apikey_…"))
                LabeledContent("") {
                    HStack {
                        if apiKeyDraft != model.apiKey {
                            Button("Save & Test") {
                                model.apiKey = apiKeyDraft
                                model.saveAPIKey()
                                Task { await model.testConnection() }
                            }
                            .disabled(apiKeyDraft.isEmpty)
                        } else if !model.apiKey.isEmpty {
                            Button("Test") {
                                Task { await model.testConnection() }
                            }
                        }
                        connectionStatusView
                    }
                }
                Text("Stored in the macOS Keychain, per server, never in a file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance") {
                Stepper(
                    "Concurrent hashes: \(model.hashConcurrency)",
                    value: $model.hashConcurrency, in: 1...8
                )
                Stepper(
                    "Concurrent uploads: \(model.uploadConcurrency)",
                    value: $model.uploadConcurrency, in: 1...6
                )
                Text("Lower values are gentler on a NAS over Wi-Fi; the defaults suit most setups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { apiKeyDraft = model.apiKey }
        .onChange(of: model.apiKey) { apiKeyDraft = model.apiKey }
        .onChange(of: model.hashConcurrency) { model.savePerformanceSettings() }
        .onChange(of: model.uploadConcurrency) { model.savePerformanceSettings() }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch model.connectionStatus {
        case .unknown:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
        }
    }
}
