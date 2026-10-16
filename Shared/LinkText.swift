import SwiftUI

/// A bubble's words with tappable links that can actually be read. Links used to take the app's accent color,
/// which is the user's own bubble color, so a pasted link vanished into it. Bare web addresses get linked too.
enum LinkText {
    static func render(_ text: String, mine: Bool) -> AttributedString {
        var s = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        linkBareAddresses(&s)
        for run in s.runs where run.link != nil {
            s[run.range].foregroundColor = mine ? .white : Clay.terracotta
            s[run.range].underlineStyle = .single
        }
        return s
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkBareAddresses(_ s: inout AttributedString) {
        guard let detector else { return }
        let plain = String(s.characters)
        let ns = plain as NSString
        for m in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
                  let r = Range(m.range, in: plain),
                  let lo = AttributedString.Index(r.lowerBound, within: s),
                  let hi = AttributedString.Index(r.upperBound, within: s) else { continue }
            if s[lo..<hi].runs.contains(where: { $0.link != nil }) { continue }
            s[lo..<hi].link = url
        }
    }
}
