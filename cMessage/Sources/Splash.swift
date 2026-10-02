import SwiftUI
import AppKit

/// The launch moment: the app icon, pressed together in front of you. A cream bubble lands on the clay slab,
/// the accent bubble presses in over it, three dimples pop in, the name settles underneath, and the whole
/// thing melts away into the chats. Under a second, and a click or key skips it.
///
/// `SplashScene` is a pure function of time so the same drawing serves the live overlay, the still
/// mockups and the frame-by-frame clip. Colors come from `Clay`, so it is ice blue in a personal build and
/// orange in the public one, and flips with light / dark on its own.
struct SplashScene: View {
    /// Seconds since launch.
    let t: Double
    /// When the fade-out starts (normally `SplashTiming.fadeAt`; a skip pulls it forward).
    var fadeAt: Double = SplashTiming.fadeAt
    var reduceMotion = false

    var body: some View {
        let fade = SplashTiming.fadeProgress(t, from: fadeAt)
        ZStack {
            Clay.sidebar
            GeometryReader { g in
                let s = min(g.size.width, g.size.height) * 0.34     // the pair of bubbles is ~a third of the short side
                let cream = motion(SplashTiming.cream)
                let accent = motion(SplashTiming.accent)
                let hint = SplashTiming.ease(t, SplashTiming.name)
                ZStack {
                    // The cream bubble, behind and up-left, tail to the left.
                    bubble(Clay.cream, tail: .leading, w: s * 0.72, h: s * 0.62, m: cream)
                        .offset(x: -s * 0.19, y: -s * 0.14)
                    // The accent bubble in front, tail to the right, with the three dents.
                    bubble(Clay.terracotta, tail: .trailing, w: s * 0.78, h: s * 0.64, m: accent)
                        .overlay {
                            HStack(spacing: s * 0.07) {
                                ForEach(0..<3, id: \.self) { i in
                                    ClayDimple(size: s * 0.085)
                                        .scaleEffect(SplashTiming.pop(t, SplashTiming.dimples[i]))
                                }
                            }
                            .offset(y: -s * 0.05)   // centered on the body (the tail hangs below it)
                        }
                        .offset(x: s * 0.19, y: s * 0.11)
                    Text(Flavor.appName)
                        .font(.system(size: s * 0.19, weight: .bold, design: .rounded))
                        .foregroundStyle(Clay.ink)
                        .opacity(hint)
                        .offset(y: s * 0.62 + (1 - hint) * s * 0.05)
                }
                .frame(width: g.size.width, height: g.size.height)
                .offset(y: -s * 0.12)
            }
        }
        .opacity(1 - fade)
        .scaleEffect(1 + fade * 0.04)
        .ignoresSafeArea()
    }

    private struct Motion { var scale: Double; var opacity: Double; var lift: Double }

    /// A bubble being pressed into the slab: it arrives a little big and floating, and lands with a small
    /// overshoot as its shadow tightens. With Reduce Motion on, it is simply there.
    private func motion(_ w: SplashTiming.Window) -> Motion {
        if reduceMotion { return Motion(scale: 1, opacity: SplashTiming.ease(t, w), lift: 0) }
        let x = SplashTiming.back(t, w)
        return Motion(scale: 1.3 - 0.3 * x, opacity: SplashTiming.ease(t, .init(w.start, w.start + 0.14)), lift: 1 - min(1, max(0, (t - w.start) / (w.end - w.start))))
    }

    private func bubble(_ color: Color, tail: HorizontalEdge, w: CGFloat, h: CGFloat, m: Motion) -> some View {
        ClaySurface(shape: ClayBubble(tail: tail), color: color, depth: 1 + m.lift * 0.9)
            .frame(width: w, height: h)
            .scaleEffect(m.scale)
            .opacity(m.opacity)
    }
}

/// Where each piece happens, in seconds after launch.
enum SplashTiming {
    struct Window { let start: Double, end: Double; init(_ s: Double, _ e: Double) { start = s; end = e } }
    static let cream = Window(0.00, 0.44)
    static let accent = Window(0.14, 0.60)
    static let dimples = [Window(0.50, 0.68), Window(0.57, 0.75), Window(0.64, 0.82)]
    static let name = Window(0.52, 0.80)
    static let fadeAt = 0.95
    static let fadeLength = 0.25
    static var total: Double { fadeAt + fadeLength }

    static func u(_ t: Double, _ w: Window) -> Double { min(1, max(0, (t - w.start) / (w.end - w.start))) }
    /// Ease-out cubic, for fades.
    static func ease(_ t: Double, _ w: Window) -> Double { let x = u(t, w); return 1 - pow(1 - x, 3) }
    /// Ease-out with a little overshoot: something pressed into place that gives slightly, then settles.
    static func back(_ t: Double, _ w: Window) -> Double {
        let x = u(t, w) - 1
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * x * x * x + c1 * x * x
    }
    /// A dimple pressed in: from nothing to full with a bounce.
    static func pop(_ t: Double, _ w: Window) -> Double { max(0, back(t, w)) }
    static func fadeProgress(_ t: Double, from fadeAt: Double) -> Double { min(1, max(0, (t - fadeAt) / fadeLength)) }
}

/// A speech bubble made of clay: a rounded slab with a soft tail hanging off one bottom corner. One continuous
/// outline (no overlapping subpaths) so `ClaySurface`'s edge highlight follows the whole silhouette.
struct ClayBubble: InsettableShape {
    var tail: HorizontalEdge
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> ClayBubble { var s = self; s.inset += amount; return s }

    func path(in rect: CGRect) -> Path {
        // The tail hangs below the body, so the body sits in the top ~84% of the frame.
        let r = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.86).insetBy(dx: inset, dy: inset)
        let c = min(r.width, r.height) * 0.34
        let drop = rect.height * 0.12 - inset       // how far the tail reaches down
        var p = Path()
        // Draw as if the tail is on the trailing side, then mirror for leading.
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c * 0.45))
        // A small pinched tail hangs off the bottom corner: out of the right edge, down to a soft point, and
        // back up onto the bottom edge, both sides curving inward like clay pulled to a point.
        let tip = CGPoint(x: r.maxX + c * 0.02, y: r.maxY + drop)
        p.addCurve(to: tip,
                   control1: CGPoint(x: r.maxX, y: r.maxY),
                   control2: CGPoint(x: r.maxX - c * 0.02, y: r.maxY + drop * 0.55))
        p.addCurve(to: CGPoint(x: r.maxX - c * 0.8, y: r.maxY),
                   control1: CGPoint(x: r.maxX - c * 0.12, y: r.maxY + drop * 0.5),
                   control2: CGPoint(x: r.maxX - c * 0.35, y: r.maxY + drop * 0.12))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        if tail == .leading {
            p = p.applying(CGAffineTransform(translationX: rect.midX * 2, y: 0).scaledBy(x: -1, y: 1))
        }
        return p
    }
}

/// The live splash over the window at launch. Runs on the display clock, ends by itself, and any click or
/// key press ends it early (the click or key is swallowed so it doesn't also land on a button underneath).
struct SplashOverlay: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var fadeAt = SplashTiming.fadeAt
    @State private var monitor: Any?
    @State private var finished = false
    @State private var chrome: NSView?

    var body: some View {
        TimelineView(.animation) { ctx in
            SplashScene(t: max(0, ctx.date.timeIntervalSince(start)), fadeAt: fadeAt, reduceMotion: reduceMotion)
        }
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        // The toolbar buttons and traffic lights live in the title bar, above any SwiftUI content, so they'd
        // float over the splash. Hide that strip the moment we're in the window and bring it back with the fade.
        .background(WindowHook { w in
            guard chrome == nil, let c = w.standardWindowButton(.closeButton)?.superview?.superview else { return }
            c.alphaValue = 0
            chrome = c
        })
        .onAppear {
            // The clock starts when the window is about to draw, not when the view was created: loading the
            // store can take a moment, and the user should see the whole thing.
            start = Date()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { e in
                // Only swallow what lands on the splash itself; the window edges keep working.
                if e.type == .leftMouseDown, let w = e.window, !w.contentLayoutRect.contains(e.locationInWindow) { return e }
                if e.type == .keyDown, e.modifierFlags.contains(.command) { return e }   // ⌘Q, ⌘, etc. still work
                DispatchQueue.main.async { skip() }
                return nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + SplashTiming.fadeAt) { fadeChrome() }
            DispatchQueue.main.asyncAfter(deadline: .now() + SplashTiming.total) { finish() }
        }
        .onDisappear { finish() }
        .allowsHitTesting(!finished)
    }

    private func skip() {
        let now = Date().timeIntervalSince(start)
        guard now < fadeAt else { return }
        fadeAt = now
        fadeChrome()
        DispatchQueue.main.asyncAfter(deadline: .now() + SplashTiming.fadeLength) { finish() }
    }

    private func fadeChrome() {
        guard let c = chrome, c.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = SplashTiming.fadeLength
            c.animator().alphaValue = 1
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        chrome?.alphaValue = 1
        onDone()
    }
}

/// Hands over the NSWindow as soon as the view lands in one (before the first frame is drawn).
private struct WindowHook: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> Hook { let v = Hook(); v.found = found; return v }
    func updateNSView(_ v: Hook, context: Context) {}
    final class Hook: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let w = window { found?(w) } }
    }
}
