import SwiftUI
import UploaderCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run History")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            if model.runs.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "clock",
                    description: Text("Each Analyze and Upload run is recorded here.")
                )
            } else {
                List(model.runs, id: \.id) { run in
                    row(for: run)
                }
            }
        }
        .frame(width: 560, height: 400)
    }

    private func row(for run: RunRecord) -> some View {
        let counters = run.counters
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text(outcomeText(run.outcome))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(outcomeColor(run.outcome).opacity(0.15), in: Capsule())
                    .foregroundStyle(outcomeColor(run.outcome))
                Spacer()
            }
            Text(summary(counters))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func summary(_ counters: RunCounters) -> String {
        var parts = [
            "\(counters.filesDiscovered.formatted()) discovered",
            "\(counters.alreadySynced.formatted()) already synced",
        ]
        if counters.uploaded > 0 {
            parts.append(
                "\(counters.uploaded.formatted()) uploaded "
                    + "(\(AppModel.bytesText(counters.bytesUploaded)))"
            )
        } else {
            parts.append("\(counters.toUpload.formatted()) to upload")
        }
        if counters.skippedRaw > 0 { parts.append("\(counters.skippedRaw) RAW skipped") }
        if counters.errors > 0 { parts.append(AppModel.pluralize(counters.errors, "error")) }
        return parts.joined(separator: " · ")
    }

    private func outcomeText(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .running: "running"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    private func outcomeColor(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .running: .blue
        case .completed: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }
}
