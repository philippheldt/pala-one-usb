import Foundation

/// One quote of a book note: quote text, optional page label and a free note.
struct Quote: Identifiable, Equatable {
    /// Stable while the file does not change around this quote.
    let id: String
    /// Position of the block in the file.
    let index: Int
    var text: String
    var pageLabel: String?
    var note: String

    var firstPage: Int? {
        guard let label = pageLabel else { return nil }
        let digits = label.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }
}

/// A `Notes/Note_<Buch>.md` file as written by the sync:
///
///     # 📝 Zitate: Titel
///     **Quelle:** `Buch.txt`
///     ...
///     > "Zitattext"
///     *(Seite 12)*
///
///     Notiz (beliebiger Markdown-Text bis zum nächsten Zitat)
///
/// Everything before the first quote is kept untouched as the header.
struct NoteDocument {
    var headerLines: [String]
    var quotes: [Quote]

    // MARK: Parsing

    static func parse(_ content: String) -> NoteDocument {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var header: [String] = []
        var quotes: [Quote] = []
        var i = 0

        while i < lines.count && !isQuoteLine(lines[i]) {
            header.append(lines[i])
            i += 1
        }
        while let last = header.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            header.removeLast()
        }

        while i < lines.count {
            var quoteLines: [String] = []
            while i < lines.count && isQuoteLine(lines[i]) {
                var l = String(lines[i].dropFirst())
                if l.hasPrefix(" ") { l.removeFirst() }
                quoteLines.append(l)
                i += 1
            }

            var j = i
            while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            var page: String?
            if j < lines.count, let p = pageLabel(in: lines[j]) {
                page = p
                i = j + 1
            }

            var noteLines: [String] = []
            while i < lines.count && !isQuoteLine(lines[i]) {
                let l = lines[i]
                noteLines.append(l.hasPrefix("\\>") ? String(l.dropFirst()) : l)
                i += 1
            }

            let text = cleanQuoteText(quoteLines.joined(separator: "\n"))
            let note = noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let index = quotes.count
            quotes.append(Quote(id: "\(index)|\(page ?? "")|\(text)", index: index,
                                text: text, pageLabel: page, note: note))
        }
        return NoteDocument(headerLines: header, quotes: quotes)
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.hasPrefix(">")
    }

    /// "*(Seite 12)*" -> "Seite 12"
    private static func pageLabel(in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("*("), t.hasSuffix(")*"), t.count > 4 else { return nil }
        return String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func cleanQuoteText(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let openers: Set<Character> = ["\"", "„", "“", "»"]
        let closers: Set<Character> = ["\"", "“", "”", "«"]
        if let f = t.first, openers.contains(f) { t.removeFirst() }
        if let l = t.last, closers.contains(l) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Header info

    var title: String? {
        guard let line = headerLines.first(where: { $0.hasPrefix("# ") }) else { return nil }
        var t = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("📝") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("Zitate:") { t = String(t.dropFirst("Zitate:".count)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? nil : t
    }

    var source: String? {
        guard let line = headerLines.first(where: { $0.contains("**Quelle:**") }),
              let a = line.firstIndex(of: "`") else { return nil }
        let rest = line[line.index(after: a)...]
        guard let b = rest.firstIndex(of: "`") else { return nil }
        return String(rest[..<b])
    }

    // MARK: Rendering

    func render() -> String {
        let header = headerLines.map { line -> String in
            line.hasPrefix("**Anzahl Zitate:**") ? "**Anzahl Zitate:** \(quotes.count)" : line
        }
        var parts: [String] = []
        let headerText = header.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !headerText.isEmpty { parts.append(headerText) }
        for q in quotes { parts.append(Self.renderBlock(q)) }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static func renderBlock(_ q: Quote) -> String {
        var lines: [String] = []
        let textLines = q.text.components(separatedBy: "\n")
        for (k, raw) in textLines.enumerated() {
            var line = raw
            if k == 0 { line = "\"" + line }
            if k == textLines.count - 1 { line += "\"" }
            lines.append(line.isEmpty ? ">" : "> " + line)
        }
        if let p = q.pageLabel, !p.isEmpty { lines.append("*(\(p))*") }
        if !q.note.isEmpty {
            lines.append("")
            for l in q.note.components(separatedBy: "\n") {
                lines.append(l.hasPrefix(">") ? "\\" + l : l)
            }
        }
        return lines.joined(separator: "\n")
    }
}
