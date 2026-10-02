import SwiftUI

/// "Call in the team": pick which of the user's team (their own from Build My Team, or the classic seven) to pull onto a project. Each gets its own chat
/// (an existing one is reused, never duplicated), and optionally they all go in one group too.
struct TeamSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let project: Contact
    /// nil = everyone on the team.
    @State private var picked: Set<UUID>?
    @State private var building = false
    private var chosen: Set<UUID> { picked ?? Set(store.team.map(\.id)) }
    @State private var asGroup = true
    @State private var opener = ""
    @State private var engine: Engine = .claude
    @State private var model = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Avatar(contact: project, size: 40)
                VStack(alignment: .leading) {
                    Text("Call in the team").font(.title2.bold())
                    Text("on \(project.name)").foregroundStyle(Clay.inkSoft)
                }
                Spacer()
                Button(store.ownTeam == nil ? "Build My Team…" : "Edit My Team…") { building = true }
                Button(chosen.count == store.team.count ? "None" : "All") {
                    picked = chosen.count == store.team.count ? [] : Set(store.team.map(\.id))
                }
            }
            List {
                ForEach(store.team) { t in
                    let on = chosen.contains(t.id)
                    let already = store.subContacts(of: project.id).contains { $0.name.caseInsensitiveCompare(t.name) == .orderedSame }
                    Button {
                        var s = chosen
                        if on { s.remove(t.id) } else { s.insert(t.id) }
                        picked = s
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Clay.terracotta : Clay.inkSoft)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(t.name).font(.headline)
                                    if already { Text("already here").font(.caption2).foregroundStyle(Clay.inkSoft) }
                                }
                                Text(t.job).font(.caption).foregroundStyle(Clay.inkSoft).lineLimit(2)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 260)
            Toggle("Also start one group chat with everyone", isOn: $asGroup)
            VStack(alignment: .leading, spacing: 4) {
                Text("Say something to start them off (optional)").font(.caption).foregroundStyle(Clay.inkSoft)
                TextField("e.g. take a look at the app and tell me what you'd change", text: $opener, axis: .vertical)
                    .lineLimit(1...3)
            }
            HStack {
                Picker("", selection: $engine) {
                    ForEach(store.availableEngines) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                .onChange(of: engine) { _, _ in model = "" }
                Picker("Model", selection: $model) {
                    ForEach(store.models(for: engine)) { m in Text(m.label).tag(m.id) }
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Call in \(chosen.count)") {
                    let members = store.team.filter { chosen.contains($0.id) }
                    store.callInTeam(on: project, members: members, asGroup: asGroup, opener: opener,
                                     engine: engine, model: model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        // A fresh team means a fresh pick (ids changed).
        .sheet(isPresented: $building, onDismiss: { picked = nil }) { TeamBuilder().environmentObject(store) }
    }
}
