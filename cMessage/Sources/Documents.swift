import Foundation

/// Documents dropped into a chat (spreadsheets, Word files, PDFs, text). Copied as-is into the attachments folder
/// under "<8 chars>-<original name>", so the agent and the user both see the real file name. Agents can't always
/// open the original (Claude's Read takes PDFs and text, not .xlsx or .docx), so `readable` makes a plain-text copy
/// beside it ("<file>.txt") the first time it's needed: tables as CSV per sheet, Word/RTF/ODT via textutil, slides
/// as their text.
enum Documents {
    /// Read straight off: text of any kind, and PDFs.
    static let direct: Set<String> = ["pdf", "txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
                                      "log", "yaml", "yml", "rtf"]
    static let textutil: Set<String> = ["doc", "docx", "odt", "wordml", "webarchive"]
    static let sheets: Set<String> = ["xlsx", "xlsm"]
    static let slides: Set<String> = ["pptx"]
    static var exts: Set<String> { direct.union(textutil).union(sheets).union(slides) }
    static let maxBytes = 100_000_000
    /// Readable copies stop here so one giant spreadsheet can't flood the agent.
    static let maxText = 2_000_000

    static func isDocument(_ path: String) -> Bool { exts.contains(ext(path)) }
    private static func ext(_ path: String) -> String { URL(fileURLWithPath: path).pathExtension.lowercased() }

    /// Copy a dropped document in. nil for anything that isn't a document we know how to read.
    static func importFile(_ src: URL, into dir: URL) -> String? {
        guard isDocument(src.path),
              let size = (try? src.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])),
              size.isRegularFile == true, (size.fileSize ?? 0) <= maxBytes else { return nil }
        let name = src.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8).lowercased())-\(name)")
        do { try FileManager.default.copyItem(at: src, to: dest); return dest.path }
        catch { Log.error("document import failed: \(error)"); return nil }
    }

    /// The name to show: the original file name without our prefix.
    static func displayName(_ path: String) -> String {
        let n = URL(fileURLWithPath: path).lastPathComponent
        let parts = n.split(separator: "-", maxSplits: 1)
        if parts.count == 2, parts[0].count == 8, parts[0].allSatisfy(\.isHexDigit) { return String(parts[1]) }
        return n
    }

    /// A path the agent can open with a plain file reader. Made (once) on demand.
    static func readable(_ path: String) -> String? {
        let e = ext(path)
        if direct.contains(e) { return path }
        let out = path + ".txt"
        if FileManager.default.fileExists(atPath: out) { return out }
        var text: String?
        if textutil.contains(e) {
            text = run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path])
        } else if sheets.contains(e) {
            text = spreadsheet(path)
        } else if slides.contains(e) {
            text = slideText(path)
        }
        guard var t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.error("couldn't make a readable copy of \(displayName(path))")
            return nil
        }
        if t.count > maxText { t = String(t.prefix(maxText)) + "\n\n[cut off here: the file is longer]" }
        do {
            try t.write(toFile: out, atomically: true, encoding: .utf8)
            return out
        } catch { return nil }
    }

    // MARK: - zip pieces (xlsx / pptx are zip files of XML)

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static func zipList(_ path: String) -> [String] {
        (run("/usr/bin/unzip", ["-Z1", path]) ?? "").split(separator: "\n").map(String.init)
    }

    private static func zipEntry(_ path: String, _ entry: String) -> Data? {
        run("/usr/bin/unzip", ["-p", path, entry]).map { Data($0.utf8) }
    }

    /// Entries like "xl/worksheets/sheet12.xml" in number order.
    private static func numbered(_ list: [String], prefix: String) -> [String] {
        func n(_ s: String) -> Int { Int(s.dropFirst(prefix.count).dropLast(4)) ?? 0 }
        return list.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".xml") && !$0.dropFirst(prefix.count).contains("/") }
            .sorted { n($0) < n($1) }
    }

    static func spreadsheet(_ path: String) -> String? {
        let list = zipList(path)
        let shared = zipEntry(path, "xl/sharedStrings.xml").map { XMLTexts(data: $0, item: "si").items } ?? []
        let names = zipEntry(path, "xl/workbook.xml").map { SheetNames(data: $0).names } ?? []
        let files = numbered(list, prefix: "xl/worksheets/sheet")
        guard !files.isEmpty else { return nil }
        var out = "Spreadsheet: \(displayName(path)) (each sheet as CSV)\n"
        for (i, f) in files.enumerated() {
            guard let d = zipEntry(path, f) else { continue }
            let rows = SheetCells(data: d, shared: shared).rows
            out += "\n## Sheet: \(i < names.count && names.count == files.count ? names[i] : "Sheet \(i + 1)")\n"
            out += rows.isEmpty ? "(empty)\n" : rows.map { $0.map(csv).joined(separator: ",") }.joined(separator: "\n") + "\n"
            if out.count > maxText { break }
        }
        return out
    }

    static func slideText(_ path: String) -> String? {
        let files = numbered(zipList(path), prefix: "ppt/slides/slide")
        guard !files.isEmpty else { return nil }
        var out = "Slides: \(displayName(path))\n"
        for (i, f) in files.enumerated() {
            guard let d = zipEntry(path, f) else { continue }
            out += "\n## Slide \(i + 1)\n" + XMLTexts(data: d, item: "p").items.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        }
        return out
    }

    private static func csv(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

/// Collects the text inside each <item> (all its <t> runs joined): shared strings ("si") or slide paragraphs ("p").
private final class XMLTexts: NSObject, XMLParserDelegate {
    private(set) var items: [String] = []
    private let item: String
    private var cur: String?
    private var inT = false

    init(data: Data, item: String) {
        self.item = item
        super.init()
        let p = XMLParser(data: data); p.delegate = self; p.parse()
    }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        let local = e.split(separator: ":").last.map(String.init) ?? e
        if local == item { cur = "" } else if local == "t" { inT = true }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inT { cur? += s } }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        let local = e.split(separator: ":").last.map(String.init) ?? e
        if local == "t" { inT = false } else if local == item, let c = cur { items.append(c); cur = nil }
    }
}

private final class SheetNames: NSObject, XMLParserDelegate {
    private(set) var names: [String] = []
    init(data: Data) { super.init(); let p = XMLParser(data: data); p.delegate = self; p.parse() }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        if e == "sheet", let n = a["name"] { names.append(n) }
    }
}

/// One worksheet's cells as rows of strings, placed by their "B7" style reference so gaps stay gaps.
private final class SheetCells: NSObject, XMLParserDelegate {
    private(set) var rows: [[String]] = []
    private let shared: [String]
    private var grid: [Int: [Int: String]] = [:]
    private var ref = "", type = "", value = "", inV = false, inT = false

    init(data: Data, shared: [String]) {
        self.shared = shared
        super.init()
        let p = XMLParser(data: data); p.delegate = self; p.parse()
        guard let last = grid.keys.max().map({ min($0, 50_000) }) else { return }
        let width = grid.values.compactMap { $0.keys.max() }.max().map { $0 + 1 } ?? 0
        rows = (1...last).map { r in (0..<width).map { grid[r]?[$0] ?? "" } }
        while let l = rows.last, l.allSatisfy(\.isEmpty) { rows.removeLast() }
    }

    private static func place(_ ref: String) -> (Int, Int)? {
        let letters = ref.prefix { $0.isLetter }.uppercased()
        guard let row = Int(ref.dropFirst(letters.count)), !letters.isEmpty else { return nil }
        let col = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        return (row, col)
    }

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        switch e {
        case "c": ref = a["r"] ?? ""; type = a["t"] ?? ""; value = ""
        case "v": inV = true
        case "t": inT = true
        default: break
        }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inV || inT { value += s } }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        switch e {
        case "v": inV = false
        case "t": inT = false
        case "c":
            var v = value
            if type == "s", let i = Int(v), i < shared.count { v = shared[i] }
            else if type == "b" { v = v == "1" ? "TRUE" : "FALSE" }
            if !v.isEmpty, let (r, c) = Self.place(ref), c < 1000 { grid[r, default: [:]][c] = v }
        default: break
        }
    }
}
