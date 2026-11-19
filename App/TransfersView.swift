import SwiftUI
import SoulseekCore

struct TransfersView: View {
    @Bindable var model: TransfersModel

    var body: some View {
        ZStack {
            GlassBackground()
            List {
                ForEach(model.transfers) { t in
                    TransferRow(
                        transfer: t,
                        speed: model.speeds[t.id] ?? 0,
                        onRetry: { model.retry(t.id) },
                        onCancel: { model.cancel(t.id) },
                        onQueuePlace: { model.queuePlace(t.id) }
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 64, for: .scrollContent)
            .overlay {
                if model.transfers.isEmpty {
                    ContentUnavailableView(
                        "No transfers",
                        systemImage: "arrow.down.circle",
                        description: Text("Download files from the Search tab.")
                    )
                }
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear completed") { model.clearCompleted() }
                    .accessibilityIdentifier("clearCompletedButton")
            }
        }
    }
}

struct TransferRow: View {
    let transfer: TransferEngine.Transfer
    let speed: Double
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onQueuePlace: () -> Void

    private var filename: String {
        let name = transfer.filename
        if let i = name.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            return String(name[name.index(after: i)...])
        }
        return name
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var isActive: Bool {
        switch transfer.state {
        case .queued, .connecting, .waiting, .downloading: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(filename)
                .font(.subheadline)
                .lineLimit(2)
                .accessibilityIdentifier("transferFilename")
            HStack {
                Text(transfer.username)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                stateLabel
                    .accessibilityIdentifier("transferState")
            }
            if case .downloading = transfer.state {
                ProgressView(value: Double(transfer.received), total: Double(max(transfer.size, 1)))
                    .tint(.orange)
                HStack {
                    Text(String(format: "%.1f / %.1f MB", Double(transfer.received) / 1_048_576, Double(transfer.size) / 1_048_576))
                    Spacer()
                    Text(String(format: "%.0f KB/s", speed / 1024))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if isFailed || transfer.state == .cancelled || isActive {
                HStack(spacing: 12) {
                    if isFailed || transfer.state == .cancelled {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("retryButton")
                    }
                    if isActive {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.glass)
                            .tint(.red)
                            .accessibilityIdentifier("cancelButton")
                        Button("Queue place", action: onQueuePlace)
                            .buttonStyle(.glass)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch transfer.state {
        case .queued:
            Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting…").font(.caption2).foregroundStyle(.secondary)
        case .waiting(let place):
            Text(place.map { "In queue #\($0)" } ?? "In queue")
                .font(.caption2).foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading").font(.caption2).foregroundStyle(.orange)
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .failed(let reason):
            Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        }
    }
}