import SwiftUI

/// "Call in the team": pick which of the user's seven personas to pull onto a project. Each gets its own chat
/// (an existing one is reused, never duplicated), and optionally they all go in one group too.
struct TeamSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let project: Contact
    @State private var picked: Set<TeamPreset> = Set(TeamPreset.allCases)
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
                Button(picked.count == TeamPreset.allCases.count ? "None" : "All") {
                    picked = picked.count == TeamPreset.allCases.count ? [] : Set(TeamPreset.allCases)
                }
            }
            List {
                ForEach(TeamPreset.allCases) { t in
                    let on = picked.contains(t)
                    let already = store.subContacts(of: project.id).contains { $0.name.caseInsensitiveCompare(t.name) == .orderedSame }
                    Button {
                        if on { picked.remove(t) } else { picked.insert(t) }
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Clay.terracotta : Clay.inkSoft)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(t.name).font(.headline)
                                    if already { Text("already here").font(.caption2).foregroundStyle(Clay.inkSoft) }
                                }
                                Text(t.role).font(.caption).foregroundStyle(Clay.inkSoft).lineLimit(2)
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
                    ForEach(Engine.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                .onChange(of: engine) { _, _ in model = "" }
                Picker("Model", selection: $model) {
                    ForEach(store.models(for: engine)) { m in Text(m.label).tag(m.id) }
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }
                Button(picked.count == 1 ? "Call in 1" : "Call in \(picked.count)") {
                    let members = TeamPreset.allCases.filter { picked.contains($0) }
                    store.callInTeam(on: project, members: members, asGroup: asGroup, opener: opener,
                                     engine: engine, model: model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }
}
