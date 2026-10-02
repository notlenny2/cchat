import SwiftUI

/// Phone version of "call in the team": tick who to pull onto a project, they each get a chat.
struct TeamSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    let project: RemoteContact
    let opened: (UUID) -> Void
    @State private var picked: Set<UUID>?
    @State private var asGroup = true
    @State private var opener = ""

    /// The Mac's team (the user's own, or the classic seven).
    private var team: [TeamMember] { client.snapshot?.team ?? TeamMember.classic }
    private var chosen: Set<UUID> { picked ?? Set(team.map(\.id)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(team) { t in
                        let on = chosen.contains(t.id)
                        Button {
                            var s = chosen
                            if on { s.remove(t.id) } else { s.insert(t.id) }
                            picked = s
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Clay.terracotta : Clay.inkSoft)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.headline).foregroundStyle(Clay.ink)
                                    Text(t.job).font(.caption).foregroundStyle(Clay.inkSoft).lineLimit(2)
                                }
                            }
                        }
                    }
                } header: { Text("Who to call in on \(project.name)") }
                Section {
                    Toggle("Also start one group chat", isOn: $asGroup)
                    TextField("Say something to start them off (optional)", text: $opener, axis: .vertical).lineLimit(1...3)
                }
            }
            .navigationTitle("Call in the team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Call in \(chosen.count)") {
                        let names = team.filter { chosen.contains($0.id) }.map(\.name)
                        Task {
                            if let id = await client.callInTeam(project.id, members: names, asGroup: asGroup,
                                                                opener: opener, engine: .claude, model: "") { opened(id) }
                            dismiss()
                        }
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
    }
}
