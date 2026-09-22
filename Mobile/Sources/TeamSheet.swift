import SwiftUI

/// Phone version of "call in the team": tick who to pull onto a project, they each get a chat.
struct TeamSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    let project: RemoteContact
    let opened: (UUID) -> Void
    @State private var picked: Set<TeamPreset> = Set(TeamPreset.allCases)
    @State private var asGroup = true
    @State private var opener = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TeamPreset.allCases) { t in
                        Button {
                            if picked.contains(t) { picked.remove(t) } else { picked.insert(t) }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: picked.contains(t) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(t) ? Clay.terracotta : Clay.inkSoft)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.headline).foregroundStyle(Clay.ink)
                                    Text(t.role).font(.caption).foregroundStyle(Clay.inkSoft).lineLimit(2)
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
                    Button("Call in \(picked.count)") {
                        let names = TeamPreset.allCases.filter { picked.contains($0) }.map(\.name)
                        Task {
                            if let id = await client.callInTeam(project.id, members: names, asGroup: asGroup,
                                                                opener: opener, engine: .claude, model: "") { opened(id) }
                            dismiss()
                        }
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}
