import SwiftUI

/// Download settings: Wi-Fi-only guard + speed limit. Persisted in UserDefaults.
struct SettingsSheet: View {
    @Bindable var appModel: AppModel
    @State private var limitText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Downloads") {
                    Toggle("Wi-Fi only", isOn: $appModel.wiFiOnlyDownloads)
                        .accessibilityIdentifier("wiFiOnlyToggle")
                    Text("Pauses downloads on cellular data and resumes them when Wi-Fi returns.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Speed limit (KB/s)")
                        Spacer()
                        TextField("0 = unlimited", text: $limitText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                            .accessibilityIdentifier("speedLimitField")
                            .onSubmit {
                                appModel.downloadLimitKBs = UInt64(max(0, Int(limitText) ?? 0))
                            }
                    }
                    Text("0 means unlimited. Applies to new and running downloads.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("Storage") {
                    HStack {
                        Text("Downloads folder")
                        Spacer()
                        Text("Files app → SoulseekiOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        appModel.downloadLimitKBs = UInt64(max(0, Int(limitText) ?? 0))
                        dismiss()
                    }
                }
            }
            .onAppear {
                limitText = appModel.downloadLimitKBs > 0 ? String(appModel.downloadLimitKBs) : ""
            }
        }
    }
}