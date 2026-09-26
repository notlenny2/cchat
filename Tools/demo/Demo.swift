import SwiftUI
import AppKit

/// Demo harness for release screenshots and the promo video. Never part of the app.
@MainActor
enum Demo {
    static let root = URL(fileURLWithPath: "/tmp/cchat-demo")
    static var data: URL { root.appendingPathComponent("data") }
    static var out: URL { root.appendingPathComponent("out") }

    static var sourdough = UUID(), pixelTeam = UUID(), trail = UUID()

    // MARK: fake data

    static var firstRun: Bool { ProcessInfo.processInfo.environment["DEMO_MODE"] == "first" }

    static func prepare() {
        let d = UserDefaults.standard
        d.set(true, forKey: "setupDone")
        if firstRun {
            // A brand-new user: no contacts, no projects folder yet.
            d.set("Sam", forKey: "userName")
            d.set(root.appendingPathComponent("projects").path, forKey: "projectsRoot")
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            return
        }
        d.set("Sam", forKey: "userName")
        d.set(root.appendingPathComponent("projects").path, forKey: "projectsRoot")
        d.set(false, forKey: "usageCollapsed")
        let usage = UsageReport(
            claude: PlanUsage(session: UsageWindow(used: 0.31, resetsAt: Date().addingTimeInterval(7200)),
                              week: UsageWindow(used: 0.22, resetsAt: Date().addingTimeInterval(400000)), asOf: Date()),
            codex: PlanUsage(session: UsageWindow(used: 0.12, resetsAt: Date().addingTimeInterval(9000)),
                             week: UsageWindow(used: 0.41, resetsAt: Date().addingTimeInterval(300000)), asOf: Date()))
        d.set(try! JSONEncoder().encode(usage), forKey: "usage")

        let fm = FileManager.default
        let photos = data.appendingPathComponent("photos")
        try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
        renderOrderPage()

        var contacts: [Contact] = []
        func project(_ name: String, _ emoji: String, _ c1: NSColor, _ c2: NSColor) -> Contact {
            let dir = root.appendingPathComponent("projects/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let icon = photos.appendingPathComponent("\(name).png")
            icon_(emoji, c1, c2, to: icon)
            let c = Contact(name: name, projectPath: dir.path, colorIndex: contacts.count, iconPath: icon.path, iconSearched: true)
            contacts.append(c); return c
        }
        func sub(_ p: Contact, _ name: String, _ color: Int) -> Contact {
            let c = Contact(name: name, projectPath: p.projectPath, parentId: p.id, role: name, colorIndex: color, iconSearched: true)
            contacts.append(c); return c
        }
        let rgb = { (r: Double, g: Double, b: Double) in NSColor(red: r, green: g, blue: b, alpha: 1) }
        let bakery = project("Sourdough Site", "🥖", rgb(0.98, 0.86, 0.62), rgb(0.91, 0.60, 0.33))
        let garden = project("Pixel Garden", "🌱", rgb(0.72, 0.90, 0.62), rgb(0.33, 0.66, 0.42))
        let hike = project("Trail Buddy", "🥾", rgb(0.70, 0.84, 0.95), rgb(0.33, 0.52, 0.78))
        let recipes = project("Recipe Box", "🍋", rgb(1.0, 0.95, 0.60), rgb(0.95, 0.78, 0.25))
        let merch = project("Band Merch", "🎸", rgb(0.96, 0.66, 0.66), rgb(0.78, 0.30, 0.36))
        let wedding = project("Wedding Planner", "💐", rgb(0.98, 0.84, 0.90), rgb(0.86, 0.52, 0.66))
        let budget = project("Home Budget", "📊", rgb(0.84, 0.80, 0.96), rgb(0.52, 0.44, 0.80))
        let designer = sub(garden, "Designer", 1), engineer = sub(garden, "Engineer", 3), director = sub(garden, "Director", 5)

        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func me(_ t: String, _ m: Double) -> Message { Message(senderId: nil, text: t, date: ago(m)) }
        func them(_ c: Contact, _ t: String, _ m: Double) -> Message { Message(senderId: c.id, text: t, date: ago(m)) }

        var convs: [Conversation] = []
        var c = Conversation(participantIds: [bakery.id])
        sourdough = c.id
        c.messages = [
            me("the menu page looks cramped on my phone", 60 * 20),
            them(bakery, "Fixed. On phones the menu is one column now, and each price sits right under its bread instead of off to the side. I checked it at iPhone size and it reads cleanly.", 60 * 20 - 2),
            me("perfect. can you make the hours bigger too", 60 * 20 - 5),
            them(bakery, "Done. Opening hours are the first thing under the logo now, in bigger type.", 60 * 20 - 6),
        ]
        c.pinned = true
        convs.append(c)

        c = Conversation(participantIds: [designer.id, engineer.id, director.id], title: "Pixel Garden Team")
        pixelTeam = c.id
        c.messages = [
            me("players keep quitting after the first level. why?", 42),
            them(designer, "The first level asks for three chores (plant, water, harvest) before anything feels magical. I'd let the first seed bloom right away so the fun comes first.", 41),
            them(engineer, "I looked at the playtest saves. 7 of 10 players quit at the watering step. The watering can is hidden behind the shed. Moving it next to the first plot is a five minute fix.", 40),
            them(director, "They fit together. Do the Engineer's fix today, since it's quick and clearly the biggest leak. Then try the instant bloom in next week's playtest and compare. Want me to have them start?", 39),
        ]
        c.suggestions = ["yes, start both", "just the quick fix", "show me the numbers"]
        c.pinned = true
        convs.append(c)

        c = Conversation(participantIds: [hike.id])
        trail = c.id
        c.messages = [
            me("is the beta ready for my hiking group?", 95),
            them(hike, "It's built and I tested the offline maps on a slow connection. Sending it goes to the 12 people in your hiking group, so I'll wait for your OK.", 93),
        ]
        c.needsYou = "OK to send the beta to 12 testers"
        c.suggestions = ["send it", "just me first", "what changed?"]
        convs.append(c)

        c = Conversation(participantIds: [recipes.id], engine: .codex)
        c.messages = [me("can it make my grocery list for the week", 60 * 5),
                      them(recipes, "Added a shopping list that builds itself from the recipes you pick for the week, grouped by aisle.", 60 * 5 - 3)]
        convs.append(c)

        c = Conversation(participantIds: [merch.id])
        c.messages = [me("shirts came back in stock", 60 * 26),
                      them(merch, "Shirts are back on the site and the sold-out banner is gone.", 60 * 26 - 2)]
        c.unread = true
        convs.append(c)

        c = Conversation(participantIds: [wedding.id])
        c.messages = [me("can you make the seating chart printable", 60 * 30),
                      them(wedding, "Done. There's a Print button on the seating chart, and it fits all 14 tables on one page.", 60 * 30 - 4)]
        convs.append(c)

        c = Conversation(participantIds: [budget.id])
        c.messages = [me("how did september go", 60 * 50),
                      them(budget, "September came in 8% under budget. Groceries went up a little, eating out went way down.", 60 * 50 - 1)]
        c.pinned = true
        convs.append(c)

        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        try! JSONEncoder().encode(StoreData(contacts: contacts, conversations: convs))
            .write(to: data.appendingPathComponent("store.json"))
    }

    static func icon_(_ emoji: String, _ top: NSColor, _ bottom: NSColor, to url: URL) {
        let size = 360.0
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSGradient(starting: top, ending: bottom)!.draw(in: r, angle: -90)
            let s = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: size * 0.5)])
            let b = s.size()
            s.draw(at: NSPoint(x: (size - b.width) / 2, y: (size - b.height) / 2))
            return true
        }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    /// The "screenshot" the bakery agent shows back: a phone-width web page.
    static func renderOrderPage() {
        let brown = Color(red: 0.36, green: 0.22, blue: 0.12), cream = Color(red: 0.99, green: 0.96, blue: 0.90)
        let page = VStack(alignment: .leading, spacing: 14) {
            HStack { Text("🥖").font(.system(size: 26)); Text("Sourdough & Co.").font(.system(size: 22, weight: .bold, design: .serif)); Spacer() }
            Text("Order for Pickup").font(.system(size: 28, weight: .heavy, design: .serif))
            ForEach([("Country Loaf", "$9", 2), ("Seeded Rye", "$10", 1), ("Olive & Rosemary", "$11", 0), ("Cinnamon Swirl", "$8", 1)], id: \.0) { n, p, q in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(n).font(.system(size: 16, weight: .semibold)); Text(p).font(.system(size: 13)).opacity(0.6) }
                    Spacer()
                    HStack(spacing: 12) { Text("−"); Text("\(q)").bold(); Text("+") }
                        .font(.system(size: 17)).padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().stroke(brown.opacity(0.3)))
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.white))
            }
            HStack {
                Label("Saturday", systemImage: "calendar"); Spacer(); Label("9:30 am", systemImage: "clock")
            }.font(.system(size: 15, weight: .medium)).padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.white))
            Text("Place order · $36").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13).background(RoundedRectangle(cornerRadius: 12).fill(brown))
        }
        .foregroundStyle(brown)
        .padding(22).frame(width: 380).background(cream)
        let r = ImageRenderer(content: page); r.scale = 2
        if let cg = r.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                .write(to: root.appendingPathComponent("order-page.png"))
        }
    }

    // MARK: driving the real app

    static weak var store: Store?
    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) } }

    static func start(_ s: Store) {
        store = s
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let w = window else { print("no window"); exit(1) }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
            if !firstRun { s.selectedId = sourdough }
            try? await Task.sleep(for: .seconds(2))
            let mode = ProcessInfo.processInfo.environment["DEMO_MODE"] ?? "shots"
            if mode == "video" { await video(s) } else if mode == "first" { await first(s) } else { await shots(s) }
            exit(0)
        }
    }

    static func shots(_ s: Store) async {
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let tag = dark ? "dark" : "light"
            for (name, id) in [("1-chat", sourdough), ("2-group", pixelTeam), ("3-needs-you", trail)] {
                s.selectedId = id
                try? await Task.sleep(for: .seconds(1.5))
                snap("\(name)-\(tag)")
            }
        }
    }

    /// The first minute: empty app, name a project, Start, land in its chat.
    static func first(_ s: Store) async {
        snap("0-first-light")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .seconds(1))
        snap("0-first-dark")
        NSApp.appearance = NSAppearance(named: .aqua)
        try? await Task.sleep(for: .seconds(1))
        await type("Sourdough Site")
        try? await Task.sleep(for: .seconds(0.5))
        snap("0-first-typed")
        submit()
        try? await Task.sleep(for: .seconds(2))
        snap("0-first-chat")
        print("contacts: \(s.contacts.map(\.name)) chats: \(s.conversations.count) folder exists: \(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/sourdough-site/CLAUDE.md").path))")
    }

    static func video(_ s: Store) async {
        let rec = Recorder(windowNumber: window!.windowNumber, to: out.appendingPathComponent("raw.mp4"))
        rec.start()
        try? await Task.sleep(for: .seconds(1.8))
        await type("Can you add a page where people can order bread for pickup?")
        try? await Task.sleep(for: .seconds(0.5))
        submit()
        await waitForReply(s)
        try? await Task.sleep(for: .seconds(4.5))
        s.send("put it live", in: sourdough)
        await waitForReply(s)
        try? await Task.sleep(for: .seconds(4))
        rec.stop()
        snap("1-chat-after-video")
    }

    static func waitForReply(_ s: Store) async {
        try? await Task.sleep(for: .seconds(0.5))
        while s.isBusy(sourdough) { try? await Task.sleep(for: .seconds(0.1)) }
    }

    static func editor() -> NSTextView? { window?.firstResponder as? NSTextView }

    static func type(_ text: String) async {
        for ch in text {
            editor()?.insertText(String(ch), replacementRange: editor()?.selectedRange() ?? NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(ch == " " ? 70 : 45))
        }
    }

    static func submit() {
        editor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    static func snap(_ name: String) {
        guard let w = window, let img = capture(w.windowNumber) else { print("snap failed \(name)"); return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent("\(name).png"))
        print("saved \(name) \(img.width)x\(img.height)")
    }
}

typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
private let createImage: CreateImageFn = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")!, to: CreateImageFn.self)

/// The window as it looks on screen (this process's own window, so no screen-recording permission needed).
func capture(_ windowNumber: Int) -> CGImage? {
    createImage(.null, 8, UInt32(windowNumber), 1 | 8)?.takeRetainedValue()
}

/// Grabs the window ~30 times a second and pipes raw frames into ffmpeg.
final class Recorder: @unchecked Sendable {
    let windowNumber: Int, dest: URL
    private let q = DispatchQueue(label: "rec")
    private var timer: DispatchSourceTimer?
    private var ff: Process?, pipe: Pipe?
    private var w = 0, h = 0, frames = 0
    private var started = Date()
    init(windowNumber: Int, to: URL) { self.windowNumber = windowNumber; dest = to }

    func start() {
        started = Date()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.grab() }
        t.resume(); timer = t
    }

    private func grab() {
        guard let img = capture(windowNumber) else { return }
        if ff == nil {
            w = img.width & ~1; h = img.height & ~1
            let p = Process(); let pp = Pipe()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(w)x\(h)", "-r", "30",
                           "-i", "-", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "12", "-pix_fmt", "yuv420p", dest.path]
            p.standardInput = pp
            try! p.run(); ff = p; pipe = pp
        }
        let bytesPerRow = w * 4
        var buf = Data(count: bytesPerRow * h)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height).offsetBy(dx: 0, dy: CGFloat(h - img.height)))
        }
        pipe?.fileHandleForWriting.write(buf)
        frames += 1
    }

    func stop() {
        q.sync { timer?.cancel(); timer = nil }
        let secs = Date().timeIntervalSince(started)
        try? pipe?.fileHandleForWriting.close()
        ff?.waitUntilExit()
        let fps = Double(frames) / secs
        try? "\(frames) \(secs) \(fps)".write(to: dest.deletingLastPathComponent().appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        print("recorded \(frames) frames in \(secs)s = \(fps) fps")
    }
}
