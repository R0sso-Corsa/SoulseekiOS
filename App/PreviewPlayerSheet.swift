import SwiftUI

/// Music preview sheet (AD-15 scope): play/pause, scrub, ±15s, and a clear
/// verdict — "plays cleanly" for good files, an error for corrupt ones.
/// Stops when dismissed; no background audio.
struct PreviewPlayerSheet: View {
    let url: URL
    @State private var player = PreviewPlayer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text(url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                switch player.status {
                case .loading:
                    ProgressView("Checking file…")
                        .accessibilityIdentifier("previewLoading")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("previewError")
                case .ready:
                    if player.verified {
                        Label("Plays cleanly — file OK", systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("previewVerified")
                    }
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )
                    .accessibilityIdentifier("previewSlider")
                    HStack {
                        Text(Self.timeText(player.currentTime))
                        Spacer()
                        Text(player.duration >= 0 ? Self.timeText(player.duration) : "--:--")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        Button { player.skip(-15) } label: {
                            Image(systemName: "gobackward.15").font(.title2)
                        }
                        .accessibilityIdentifier("previewBack15")
                        Button { player.playPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                        }
                        .accessibilityIdentifier("previewPlayPause")
                        Button { player.skip(15) } label: {
                            Image(systemName: "goforward.15").font(.title2)
                        }
                        .accessibilityIdentifier("previewForward15")
                    }
                    .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("previewDoneButton")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { player.load(url) }
        .onDisappear { player.stop() }
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}