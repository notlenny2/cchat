import SwiftUI

/// "Build my team": a three-step wizard for the user's own planning team (their roles, their personalities).
/// 1 Start: describe it and get a draft, start from the classic seven, or start blank.
/// 2 People: add, remove and edit each seat (name, what they care about, what they're like, final word).
/// 3 Review: look it over and save. "Call in the team" then offers these people on every project.
struct TeamBuilder: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    private enum Step: Int { case start, people, review }
    @State private var step: Step = .start
    @State private var members: [TeamMember] = []
    @State private var selected: UUID?
    @State private var describe = ""
    @State private var drafting = false
    @State private var draftFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch step {
            case .start: start
            case .people: people
            case .review: review
            }
        }
        .padding(22)
        .frame(width: 680, height: 600)
        .background(Clay.canvas)
        .foregroundStyle(Clay.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(["Build your team", "Who's on it?", "Look it over"][step.rawValue]).font(.title.bold())
                Text(["The people you want in the room when you make a call. Each one becomes someone you can text on any project.",
                      "Give each seat a name, what they care about, and what they're like. The more personality, the better they argue.",
                      "Next time you call in the team on a project, these are the people who show up."][step.rawValue])
                    .foregroundStyle(Clay.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle().fill(i <= step.rawValue ? Clay.terracotta : Clay.peach).frame(width: 8, height: 8)
                }
            }
        }
    }

    // MARK: Step 1

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Describe it and I'll draft it", systemImage: "sparkles").font(.headline)
                TextField("e.g. a writers' room for my novel: a tough editor, a hype person, and someone who reads like a teenager",
                          text: $describe, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Clay.cream))
                HStack {
                    if draftFailed {
                        Text("Couldn't draft that one. Check Claude is signed in, or start from one of the others.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    if drafting { ProgressView().controlSize(.small) }
                    Button(drafting ? "Drafting…" : "Draft my team") { draft() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(drafting || describe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .clay(Clay.sidebar, radius: 18)

            HStack(spacing: 14) {
                choice("Start from the classic seven", "Director, Designer, Optimizer, Engineer, Salesman, Marketer, Futurist. Tweak them however you like.",
                       "person.3.fill") { begin(TeamMember.classic.map { var m = $0; m.id = UUID(); return m }) }
                choice("Start from scratch", "An empty room. Add each person yourself.", "plus.circle") {
                    begin([TeamMember(name: "")])
                }
            }
            if store.ownTeam != nil {
                HStack(spacing: 14) {
                    choice("Keep editing my team", store.team.map(\.name).joined(separator: ", "), "pencil") { begin(store.team) }
                    choice("Go back to the classic seven", "Forget my team. People already on projects stay put.",
                           "arrow.uturn.backward") { store.setTeam(nil); dismiss() }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func choice(_ title: String, _ detail: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(Clay.terracotta).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(Clay.inkSoft).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clay(Clay.cream, radius: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func begin(_ team: [TeamMember]) {
        members = team
        selected = team.first?.id
        step = .people
    }

    private func draft() {
        drafting = true
        draftFailed = false
        let text = describe
        Task {
            let team = await store.draftTeam(from: text)
            drafting = false
            if let team { begin(team) } else { draftFailed = true }
        }
    }

    // MARK: Step 2

    private var people: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(members) { m in
                                Button { selected = m.id } label: {
                                    HStack(spacing: 8) {
                                        Seat(member: m, size: 28)
                                        Text(m.isBlank ? "New person" : m.name)
                                            .foregroundStyle(m.isBlank ? Clay.inkSoft : Clay.ink)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        if m.lastWord {
                                            Image(systemName: "star.fill").font(.caption).foregroundStyle(Clay.terracotta)
                                                .help("Gets the final word")
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(selected == m.id ? Clay.peach : Color.clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack {
                        Button {
                            let m = TeamMember(name: "")
                            members.append(m)
                            selected = m.id
                        } label: { Label("Add", systemImage: "plus") }
                            .disabled(members.count >= 12)
                        Spacer()
                        Button {
                            guard let i = members.firstIndex(where: { $0.id == selected }) else { return }
                            members.remove(at: i)
                            selected = members.isEmpty ? nil : members[min(i, members.count - 1)].id
                        } label: { Image(systemName: "minus") }
                            .disabled(selected == nil)
                            .help("Take this person off the team")
                    }
                }
                .padding(10)
                .frame(width: 200)
                .clay(Clay.sidebar, radius: 16)

                if let i = members.firstIndex(where: { $0.id == selected }) {
                    editor($members[i])
                } else {
                    Text("Add someone to get started.").foregroundStyle(Clay.inkSoft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack {
                Button("Back") { step = .start }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Next") { step = .review }
                    .keyboardShortcut(.defaultAction)
                    .disabled(members.allSatisfy(\.isBlank))
            }
        }
    }

    private func editor(_ m: Binding<TeamMember>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Name") {
                TextField("like Editor, Skeptic, Coach", text: m.name)
                    .textFieldStyle(.plain).font(.title3.bold())
            }
            field("What do they care about?") {
                TextEditor(text: m.job).scrollContentBackground(.hidden).frame(minHeight: 80)
            }
            field("What are they like?") {
                TextEditor(text: m.personality).scrollContentBackground(.hidden).frame(minHeight: 60)
            }
            Toggle(isOn: Binding(get: { m.wrappedValue.lastWord }, set: { on in
                for i in members.indices { members[i].lastWord = false }
                m.wrappedValue.lastWord = on
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gets the final word")
                    Text("In a group they answer last, weigh what everyone said and make the call.")
                        .font(.caption).foregroundStyle(Clay.inkSoft)
                }
            }
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Clay.inkSoft)
            content()
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Clay.cream))
        }
    }

    // MARK: Step 3

    private func card(_ m: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Seat(member: m, size: 34)
                Text(m.name).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if m.lastWord {
                    Text("final word").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Clay.terracotta)).foregroundStyle(.white)
                }
            }
            if !m.job.isEmpty { Text(m.job).font(.callout).lineLimit(4) }
            if !m.personality.isEmpty {
                Text(m.personality).font(.caption).italic().foregroundStyle(Clay.inkSoft).lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .clay(Clay.cream, radius: 16)
    }

    private var review: some View {
        let kept = members.filter { !$0.isBlank }
        return VStack(spacing: 14) {
            ScrollView {
                // Rows of two in plain stacks: lazy containers have crashed the Mac app before.
                VStack(spacing: 12) {
                    ForEach(Array(stride(from: 0, to: kept.count, by: 2)), id: \.self) { i in
                        HStack(alignment: .top, spacing: 12) {
                            card(kept[i])
                            if i + 1 < kept.count { card(kept[i + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
                .padding(4)
            }
            if !kept.contains(where: \.lastWord) {
                Text("Nobody has the final word, so in a group they'll just answer in turn.")
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            }
            HStack {
                Button("Back") { step = .people }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save My Team") { store.setTeam(kept); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A team member's little clay circle with their initials (they aren't contacts yet, so no photo).
private struct Seat: View {
    let member: TeamMember
    var size: CGFloat

    var body: some View {
        let words = member.name.split(separator: " ").prefix(2).compactMap(\.first)
        let tone = Clay.tones[member.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Clay.tones.count]
        Circle()
            .fill(LinearGradient(colors: tone, startPoint: .top, endPoint: .bottom))
            .overlay(Text(words.isEmpty ? "?" : String(words).uppercased())
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
