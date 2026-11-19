import SwiftUI
import SoulseekCore
import SoulseekProtocol

/// Buddy list: watched users with live online/away/offline status.
struct BuddiesSheet: View {
    let appModel: AppModel
    @State private var newName = ""
    @State private var selectedUser: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add username…", text: $newName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("buddyNameField")
                        Button("Add") {
                            appModel.buddyModel.add(newName)
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("addBuddyButton")
                    }
                    if let error = appModel.buddyModel.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Buddies") {
                    if appModel.buddyModel.buddies.isEmpty {
                        Text("No buddies yet").foregroundStyle(.secondary)
                    }
                    ForEach(appModel.buddyModel.buddies) { buddy in
                        Button {
                            selectedUser = buddy.username
                        } label: {
                            HStack {
                                Circle()
                                    .fill(color(buddy.status))
                                    .frame(width: 8, height: 8)
                                Text(buddy.username)
                                    .accessibilityIdentifier("buddyRow")
                                Spacer()
                                if let files = buddy.files {
                                    Text("\(files) files")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                appModel.buddyModel.remove(buddy.username)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Buddies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(
                get: { selectedUser != nil },
                set: { if !$0 { selectedUser = nil } }
            )) {
                if let username = selectedUser {
                    UserView(appModel: appModel, username: username)
                }
            }
        }
    }

    private func color(_ status: UserStatus.Status) -> Color {
        switch status {
        case .online: return .green
        case .away: return .orange
        case .offline: return .gray
        }
    }
}