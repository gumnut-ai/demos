import SwiftUI
import UploaderCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Draft of the key being typed; committed to the model (and Keychain)
    /// only on Save & Test, so the rest of the app never sees a partial key.
    @State private var apiKeyDraft = ""
    /// Drafts of the server URL and target library; committed together on
    /// Apply Server Settings so a run can never target an edited-but-
    /// unapplied destination while the database still holds the old
    /// destination's sync state.
    @State private var serverURLDraft = ""
    @State private var libraryDraft: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURLDraft, prompt: Text(Store.defaultServerURL))
                    .autocorrectionDisabled()
                Picker("Library", selection: $libraryDraft) {
                    Text("Account default").tag(String?.none)
                    ForEach(model.libraries, id: \.id) { library in
                        Text(library.name).tag(Optional(library.id))
                    }
                }
                LabeledContent("") {
                    Button("Apply Server Settings") {
                        model.applyServerSettings(
                            serverURL: serverURLDraft, libraryId: libraryDraft
                        )
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
                        // Saving/testing acts on the applied server; while the
                        // URL draft differs, "Connected" would refer to a
                        // different destination than the field shows.
                        if apiKeyDraft != model.apiKey {
                            Button("Save & Test") {
                                model.saveAPIKey(apiKeyDraft)
                                Task { await model.testConnection() }
                            }
                            .disabled(
                                apiKeyDraft.isEmpty
                                    || serverURLDraft != model.serverURLString
                                    || model.isRunning
                            )
                        } else if !model.apiKey.isEmpty {
                            Button("Test") {
                                Task { await model.testConnection() }
                            }
                            .disabled(serverURLDraft != model.serverURLString)
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
        .onAppear {
            apiKeyDraft = model.apiKey
            serverURLDraft = model.serverURLString
            libraryDraft = model.selectedLibraryId
        }
        .onChange(of: model.apiKey) { apiKeyDraft = model.apiKey }
        .onChange(of: model.serverURLString) { serverURLDraft = model.serverURLString }
        .onChange(of: model.selectedLibraryId) { libraryDraft = model.selectedLibraryId }
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
