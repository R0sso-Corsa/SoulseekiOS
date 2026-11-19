import SwiftUI
import SoulseekCore

/// Private-room management: invite, members, operators, leave/disband.
struct PrivateRoomSheet: View {
    let chatModel: ChatModel
    let appModel: AppModel
    let room: String
    @State private var inviteName = ""
    @Environment(\.dismiss) private var dismiss

    private var conv: ChatEngine.Conversation? { chatModel.conversation("room:\(room)") }
    private var me: String { appModel.username }
    private var isOwner: Bool { conv?.owner == me }
    private var isOperator: Bool { conv?.operators.contains(me) == true }
    private var operators: [String] { conv?.operators ?? [] }
    private var allMembers: [String] {
        var names = Set(conv?.privateMembers ?? [])
        names.formUnion(operators)
        names.remove(me)
        if let owner = conv?.owner { names.remove(owner) }
        return names.sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Invite") {
                    HStack {
                        TextField("Username…", text: $inviteName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("inviteNameField")
                        Button("Invite") {
                            chatModel.invite(inviteName, to: room)
                            inviteName = ""
                        }
                        .disabled(inviteName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("inviteButton")
                    }
                    ForEach(appModel.buddyModel.buddies) { buddy in
                        Button {
                            chatModel.invite(buddy.username, to: room)
                        } label: {
                            Label("Invite \(buddy.username)", systemImage: "person.badge.plus")
                        }
                    }
                }
                Section("Members") {
                    if let owner = conv?.owner {
                        HStack {
                            Text(owner)
                            Spacer()
                            Text("owner").font(.caption2).foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("memberRow")
                    }
                    ForEach(allMembers, id: \.self) { name in
                        HStack {
                            Text(name)
                                .accessibilityIdentifier("memberRow")
                            Spacer()
                            if operators.contains(name) {
                                Text("op").font(.caption2).foregroundStyle(.teal)
                            }
                            if isOwner || (isOperator && !operators.contains(name)) {
                                Menu {
                                    if isOwner {
                                        if operators.contains(name) {
                                            Button("Remove operator") { chatModel.removeOperator(name, in: room) }
                                        } else {
                                            Button("Make operator") { chatModel.makeOperator(name, in: room) }
                                        }
                                    }
                                    Button("Remove from group", role: .destructive) {
                                        chatModel.removeMember(name, from: room)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityIdentifier("memberMenu")
                            }
                        }
                    }
                    if allMembers.isEmpty && conv?.owner == nil {
                        Text("No members yet").foregroundStyle(.secondary)
                    }
                }
                if isOwner {
                    Section {
                        Button("Disband group", role: .destructive) {
                            chatModel.cancelOwnership(of: room)
                            dismiss()
                        }
                        .accessibilityIdentifier("disbandButton")
                    } footer: {
                        Text("Cancels your ownership. Members keep the room until they leave.")
                    }
                }
                Section {
                    Button("Leave group", role: .destructive) {
                        chatModel.leavePrivateRoom(room)
                        dismiss()
                    }
                    .accessibilityIdentifier("leavePrivateButton")
                }
            }
            .navigationTitle("Manage group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}