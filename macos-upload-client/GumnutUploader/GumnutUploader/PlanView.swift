import QuickLookThumbnailing
import SwiftUI
import UploaderCore

/// Stats cards, the directory tree with exclusion checkboxes, the per-directory
/// file list, and the live activity bar — the review gate in visual form.
struct PlanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            StatsCardsView()
            Divider()
            if model.planTree != nil {
                HSplitView {
                    DirectoryTreeView()
                        .frame(minWidth: 280, idealWidth: 340)
                        .frame(maxHeight: .infinity)
                    FileListView()
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No plan yet",
                    systemImage: "folder.badge.questionmark",
                    description: Text(
                        model.roots.isEmpty
                            ? "Add a folder in the sidebar, then run Analyze."
                            : "Run Analyze to scan the selected folder."
                    )
                )
                .frame(maxHeight: .infinity)
            }
            if model.isRunning || !model.statusLine.isEmpty {
                Divider()
                ActivityBarView()
            }
        }
    }
}

struct StatsCardsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatCard(
                    title: "To upload",
                    value: model.pendingFiles.formatted(),
                    subtitle: AppModel.bytesText(model.pendingBytes),
                    color: .blue
                )
                StatCard(
                    title: "Already in Gumnut",
                    value: (model.counts[.synced] ?? 0).formatted(),
                    color: .green
                )
                if let uploaded = model.lastUpload?.uploaded {
                    StatCard(
                        title: "Uploaded this run",
                        value: uploaded.formatted(),
                        subtitle: AppModel.bytesText(model.lastUpload?.bytesUploaded ?? 0),
                        color: .green
                    )
                }
                StatCard(
                    title: "Skipped (RAW)",
                    value: (model.counts[.skippedRaw] ?? 0).formatted(),
                    color: .orange
                )
                StatCard(
                    title: "Unsupported",
                    value: (model.counts[.skippedUnsupported] ?? 0).formatted(),
                    color: .secondary
                )
                StatCard(
                    title: "Excluded by you",
                    value: (model.counts[.excluded] ?? 0).formatted(),
                    color: .secondary
                )
                StatCard(
                    title: "Errors",
                    value: (model.counts[.error] ?? 0).formatted(),
                    color: (model.counts[.error] ?? 0) > 0 ? .red : .secondary
                )
                if let analysis = model.lastAnalysis {
                    StatCard(
                        title: "Duplicates on disk",
                        value: analysis.counters.duplicateLocalFiles.formatted(),
                        color: .secondary
                    )
                    if analysis.counters.deferredRecentlyModified > 0 {
                        StatCard(
                            title: "Deferred",
                            value: analysis.counters.deferredRecentlyModified.formatted(),
                            subtitle: "just modified; next run",
                            color: .secondary
                        )
                    }
                }
            }
            .padding(8)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String?
    var color: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            // Blank placeholder keeps subtitle-less cards the same height.
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 108, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DirectoryTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedDirectory) {
            if let tree = model.planTree {
                OutlineGroup(tree, children: \.children) { node in
                    row(for: node)
                        .tag(node.id)
                }
            }
        }
    }

    private func row(for node: PlanDirectoryNode) -> some View {
        HStack {
            Image(systemName: node.id.isEmpty ? "externaldrive" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                Text(summary(for: node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isFullySynced(node) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Everything uploadable in this folder is in Gumnut")
            } else if !node.id.isEmpty {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { !model.isDirectoryExcluded(node.id) },
                        set: { include in
                            model.setExcluded(
                                kind: .directory, relPath: node.id, excluded: !include
                            )
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(
                    model.isExcludedByAncestor(node.id)
                        ? "Excluded by a parent folder — include the parent to change this"
                        : "Include this folder and everything inside it"
                )
                .disabled(model.isRunning || model.isExcludedByAncestor(node.id))
            }
        }
    }

    /// "Everything uploadable is synced": nothing pending or errored, and at
    /// least one file made it up. RAW, unsupported, and excluded files don't
    /// block the checkmark — they can't or won't upload by design.
    private func isFullySynced(_ node: PlanDirectoryNode) -> Bool {
        node.count(.synced) > 0
            && node.count(.pending) == 0
            && node.count(.error) == 0
    }

    private func summary(for node: PlanDirectoryNode) -> String {
        var parts: [String] = []
        if node.count(.pending) > 0 {
            parts.append(
                "\(node.count(.pending)) to upload (\(AppModel.bytesText(node.pendingBytes)))"
            )
        }
        if node.count(.synced) > 0 { parts.append("\(node.count(.synced)) synced") }
        if node.count(.skippedRaw) > 0 { parts.append("\(node.count(.skippedRaw)) RAW") }
        if node.count(.excluded) > 0 { parts.append("\(node.count(.excluded)) excluded") }
        if node.count(.error) > 0 { parts.append(AppModel.pluralize(node.count(.error), "error")) }
        return parts.isEmpty ? "nothing to sync" : parts.joined(separator: " · ")
    }
}

struct FileListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.selectedDirectory == nil {
                ContentUnavailableView(
                    "Select a folder",
                    systemImage: "folder",
                    description: Text("Files in the selected folder appear here.")
                )
            } else if model.directoryFiles.isEmpty {
                ContentUnavailableView(
                    "No files here",
                    systemImage: "doc",
                    description: Text("This folder contains no files.")
                )
            } else {
                VStack(spacing: 0) {
                    List(model.directoryFiles, id: \.id) { file in
                        row(for: file)
                    }
                    if model.directoryFilesTotal > model.directoryFiles.count {
                        Divider()
                        Text(
                            "Showing the first \(model.directoryFiles.count.formatted()) of "
                                + "\(AppModel.pluralize(model.directoryFilesTotal, "file")) — "
                                + "select a subfolder to narrow down."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                    }
                }
            }
        }
    }

    private func row(for file: FileRecord) -> some View {
        HStack {
            statusIcon(for: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: file))
                Text(statusText(for: file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppModel.bytesText(file.size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // The checkbox means "include in the upload plan" — only shown
            // where an upload could happen. Synced/RAW/unsupported files
            // have nothing to include (and nothing here ever deletes).
            if showsIncludeToggle(for: file.status) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { !model.isFileExcluded(file.relPath) },
                        set: { include in
                            model.setExcluded(
                                kind: .file, relPath: file.relPath, excluded: !include
                            )
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(
                    model.isExcludedByAncestor(file.relPath)
                        ? "Excluded by a parent folder — include the parent to change this"
                        : "Include this file"
                )
                .disabled(model.isRunning || model.isExcludedByAncestor(file.relPath))
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
    }

    /// Files from subdirectories show their path below the selected folder,
    /// so "sub/IMG_001.jpg" is distinguishable from a sibling "IMG_001.jpg".
    private func displayName(for file: FileRecord) -> String {
        guard let directory = model.selectedDirectory, file.parentDir != directory else {
            return file.fileName
        }
        return directory.isEmpty
            ? file.relPath
            : String(file.relPath.dropFirst(directory.count + 1))
    }

    private func showsIncludeToggle(for status: FileStatus) -> Bool {
        switch status {
        case .pending, .error, .excluded: true
        case .synced, .skippedRaw, .skippedUnsupported: false
        }
    }

    private func statusIcon(for status: FileStatus) -> some View {
        let (name, color): (String, Color) =
            switch status {
            case .pending: ("arrow.up.circle", .blue)
            case .synced: ("checkmark.circle.fill", .green)
            case .excluded: ("minus.circle", .secondary)
            case .skippedRaw: ("camera.aperture", .orange)
            case .skippedUnsupported: ("questionmark.circle", .secondary)
            case .error: ("exclamationmark.triangle.fill", .red)
            }
        return Image(systemName: name).foregroundStyle(color)
    }

    private func statusText(for file: FileRecord) -> String {
        switch file.status {
        case .pending: "will upload"
        case .synced: "in Gumnut"
        case .excluded: "excluded"
        case .skippedRaw: "RAW — not supported yet"
        case .skippedUnsupported: "not a supported photo or video"
        case .error: file.errorMessage ?? "error"
        }
    }
}

struct ActivityBarView: View {
    @Environment(AppModel.self) private var model
    @State private var showIssues = false
    @State private var showUploadDetails = false

    var body: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                if let fraction = model.fractionComplete {
                    ProgressView(value: fraction)
                        .frame(width: 160)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(model.statusLine)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !model.activeUploads.isEmpty {
                Button("Details") {
                    showUploadDetails = true
                }
                .buttonStyle(.borderless)
                .help("The files uploading right now")
                .popover(isPresented: $showUploadDetails) {
                    UploadDetailsView()
                }
            }
            if !model.issues.isEmpty {
                Button(AppModel.pluralize(model.issues.count, "issue")) {
                    showIssues = true
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showIssues) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 440, height: 260)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// What is in flight right now — nothing historical; finished files drop off.
struct UploadDetailsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Uploading \(model.activeUploads.count.formatted())")
                    .font(.headline)
                Spacer()
                if let speed = model.uploadSpeedText {
                    Text(speed)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if model.activeUploads.isEmpty {
                Text("Nothing in flight right now.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.activeUploads) { upload in
                    row(for: upload)
                }
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private func row(for upload: AppModel.ActiveUpload) -> some View {
        HStack(spacing: 10) {
            FileThumbnailView(url: upload.fileURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(upload.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: upload.fraction ?? 0)
                Text(
                    "\(AppModel.bytesText(upload.bytesSent)) of "
                        + "\(AppModel.bytesText(upload.bytesTotal))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Quick Look thumbnail for a file being uploaded; read-only, and only
/// requested while the popover is showing. Falls back to a generic icon.
struct FileThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 44, height: 44),
                scale: 2, representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request).nsImage
        }
    }
}
