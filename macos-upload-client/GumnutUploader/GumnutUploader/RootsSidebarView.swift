import SwiftUI
import UniformTypeIdentifiers
import UploaderCore

struct RootsSidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showFolderPicker = false
    @State private var rootPendingRemoval: Root?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRootId) {
            Section("Folders") {
                ForEach(model.roots, id: \.id) { root in
                    row(for: root)
                        .tag(root.id!)
                        .contextMenu {
                            Button("Remove from app…", role: .destructive) {
                                rootPendingRemoval = root
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Folder…", systemImage: "plus") {
                    showFolderPicker = true
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                Spacer()
            }
            .padding(8)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.addRoot(url: url)
            }
        }
        .confirmationDialog(
            "Remove \((rootPendingRemoval?.path as NSString?)?.lastPathComponent ?? "folder")?",
            isPresented: Binding(
                get: { rootPendingRemoval != nil },
                set: { if !$0 { rootPendingRemoval = nil } }
            )
        ) {
            Button("Remove from app", role: .destructive) {
                if let id = rootPendingRemoval?.id {
                    model.removeRoot(id)
                }
                rootPendingRemoval = nil
            }
        } message: {
            Text(
                "Only this app's records are removed — files on disk and photos "
                    + "already in Gumnut are never touched."
            )
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private func row(for root: Root) -> some View {
        HStack {
            Toggle(
                "",
                isOn: Binding(
                    get: { root.included },
                    set: { model.setRootIncluded(root.id!, included: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Include this folder in the next scan")
            .disabled(model.isRunning)

            VStack(alignment: .leading, spacing: 2) {
                Text((root.path as NSString).lastPathComponent)
                Text(root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
