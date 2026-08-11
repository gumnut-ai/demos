import SwiftUI
import UploaderCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showHistory = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            RootsSidebarView()
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isRunning {
                    Button("Cancel", systemImage: "stop.circle") {
                        model.cancel()
                    }
                    .help("Stop the current run — progress so far is kept")
                } else {
                    Button("Analyze", systemImage: "magnifyingglass") {
                        model.analyze()
                    }
                    .disabled(!model.canAnalyze)
                    .help("Scan, hash, and check folders against Gumnut. Uploads nothing.")

                    Button {
                        model.upload()
                    } label: {
                        Label(uploadTitle, systemImage: "arrow.up.circle")
                    }
                    .disabled(!model.canUpload)
                    .help("Upload the reviewed plan to Gumnut.")
                }
                Button("History", systemImage: "clock") {
                    showHistory = true
                }
                .help("Run history — what each Analyze and Upload did")
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .alert(
            "Gumnut Uploader",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var uploadTitle: String {
        model.pendingFiles > 0
            ? "Upload \(model.pendingFiles.formatted()) (\(AppModel.bytesText(model.pendingBytes)))"
            : "Upload"
    }

    @ViewBuilder
    private var detail: some View {
        if let storeError = model.storeError {
            ContentUnavailableView(
                "Local database unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(storeError)
            )
        } else if model.apiKey.isEmpty {
            SetupPromptView()
        } else {
            PlanView()
        }
    }
}

/// First-run prompt: everything configurable lives in Settings.
struct SetupPromptView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Connect to Gumnut")
                .font(.title2)
            Text(
                "Add your API key in Settings, pick your folders in the sidebar, "
                    + "then Analyze. Nothing uploads until you approve the plan, and "
                    + "this app can never modify or delete files on disk."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)
            SettingsLink {
                Text("Open Settings…")
            }
        }
        .padding(40)
    }
}
