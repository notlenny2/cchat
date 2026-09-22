import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// cChat's look: soft modeling clay, taken from the Clay app icon. Warm peach and cream, terracotta
/// for the user, everything slightly puffy with a light top edge, a darker underside and a soft warm shadow.
/// Every color has a dark-mode twin (fired clay: cocoa browns instead of peach).
enum Clay {
    static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { a in
            let d = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = d ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    // Public release = warm orange-and-white clay. the user's own build (CCHAT_PERSONAL) = the same clay in ice blue,
    // so the two are never confused on one Mac. The names stay the warm ones; `terracotta` is just "the accent".
    #if CCHAT_PERSONAL
    static let canvas     = dyn((0.929, 0.957, 0.980), (0.086, 0.114, 0.149))   // frosted table
    static let sidebar    = dyn((0.831, 0.910, 0.965), (0.106, 0.145, 0.192))   // ice slab
    static let cream      = dyn((0.973, 0.988, 1.000), (0.153, 0.204, 0.263))   // agent bubbles: snow
    static let peach      = dyn((0.780, 0.886, 0.961), (0.180, 0.243, 0.314))
    static let terracotta = dyn((0.212, 0.518, 0.800), (0.247, 0.529, 0.816))   // the user, accents: glacier blue (white text stays readable)
    static let plum       = dyn((0.604, 0.463, 0.769), (0.557, 0.427, 0.722))   // other agents writing for the user
    static let ink        = dyn((0.129, 0.212, 0.294), (0.918, 0.953, 0.984))   // text on ice
    static let inkSoft    = dyn((0.376, 0.471, 0.557), (0.627, 0.706, 0.780))
    static let shadow     = dyn((0.157, 0.302, 0.439), (0.0, 0.0, 0.0))
    #else
    static let canvas     = dyn((0.953, 0.925, 0.894), (0.145, 0.118, 0.102))   // the table the clay sits on
    static let sidebar    = dyn((0.965, 0.878, 0.816), (0.180, 0.141, 0.118))   // peach slab
    static let cream      = dyn((0.988, 0.965, 0.925), (0.263, 0.212, 0.180))   // agent bubbles
    static let peach      = dyn((0.976, 0.843, 0.749), (0.310, 0.231, 0.192))
    static let terracotta = dyn((0.906, 0.463, 0.365), (0.851, 0.420, 0.329))   // the user, accents
    static let plum       = dyn((0.604, 0.463, 0.769), (0.557, 0.427, 0.722))   // other agents writing for the user
    static let ink        = dyn((0.290, 0.212, 0.176), (0.957, 0.914, 0.867))   // text on clay
    static let inkSoft    = dyn((0.545, 0.447, 0.392), (0.745, 0.671, 0.612))
    static let shadow     = dyn((0.420, 0.259, 0.180), (0.0, 0.0, 0.0))
    #endif

    /// Avatar clays: terracotta, sage, butter, clay blue, lilac, cocoa, apricot, teal.
    static let tones: [[Color]] = [
        [Color(red: 0.93, green: 0.55, blue: 0.45), Color(red: 0.84, green: 0.42, blue: 0.33)],
        [Color(red: 0.66, green: 0.77, blue: 0.62), Color(red: 0.51, green: 0.64, blue: 0.48)],
        [Color(red: 0.97, green: 0.83, blue: 0.52), Color(red: 0.90, green: 0.70, blue: 0.36)],
        [Color(red: 0.60, green: 0.72, blue: 0.84), Color(red: 0.45, green: 0.58, blue: 0.73)],
        [Color(red: 0.78, green: 0.68, blue: 0.87), Color(red: 0.64, green: 0.53, blue: 0.77)],
        [Color(red: 0.66, green: 0.52, blue: 0.44), Color(red: 0.52, green: 0.39, blue: 0.32)],
        [Color(red: 0.98, green: 0.72, blue: 0.56), Color(red: 0.92, green: 0.58, blue: 0.42)],
        [Color(red: 0.54, green: 0.76, blue: 0.74), Color(red: 0.38, green: 0.62, blue: 0.60)],
    ]
}

/// A shape made of clay: a slightly lighter top, a highlight along the top edge, a darker lip along
/// the bottom, and a soft warm shadow underneath.
struct ClaySurface<S: InsettableShape>: View {
    let shape: S
    let color: Color
    var depth: CGFloat = 1

    var body: some View {
        shape
            .fill(color)
            .overlay(shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.22 * depth), location: 0),
                                                       .init(color: .clear, location: 0.35),
                                                       .init(color: .clear, location: 0.8),
                                                       .init(color: .black.opacity(0.07 * depth), location: 1)],
                                               startPoint: .top, endPoint: .bottom)))
            .overlay(shape.inset(by: 0.75).stroke(LinearGradient(colors: [.white.opacity(0.55 * depth), .white.opacity(0), .black.opacity(0.12 * depth)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
            .shadow(color: Clay.shadow.opacity(0.20 * depth), radius: 6 * depth, x: 0, y: 4 * depth)
            .shadow(color: Clay.shadow.opacity(0.10 * depth), radius: 1, x: 0, y: 1)
    }
}

extension View {
    func clay(_ color: Color, radius: CGFloat = 20, depth: CGFloat = 1) -> some View {
        background(ClaySurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), color: color, depth: depth))
    }
    func clayCapsule(_ color: Color, depth: CGFloat = 1) -> some View {
        background(ClaySurface(shape: Capsule(), color: color, depth: depth))
    }
}

/// A dent pressed into the clay, like the typing dots on the icon.
struct ClayDimple: View {
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(Clay.shadow.opacity(0.28))
            .overlay(Circle().stroke(LinearGradient(colors: [Clay.shadow.opacity(0.35), .white.opacity(0.7)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: max(1, size * 0.14)))
            .frame(width: size, height: size)
    }
}

/// The three dents that pulse while an agent is typing.
struct ClayTypingDots: View {
    var dot: CGFloat = 8
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * 5
            HStack(spacing: dot * 0.6) {
                ForEach(0..<3) { i in
                    ClayDimple(size: dot)
                        .scaleEffect(0.82 + 0.18 * max(0, sin(t - Double(i) * 0.9)))
                        .opacity(0.55 + 0.45 * max(0, sin(t - Double(i) * 0.9)))
                }
            }
        }
    }
}
