import Foundation
import AppKit

struct BookNotes: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var title: String
    var source: String?
    var quotes: [Quote]
    var modified: Date

    var sortedQuotes: [Quote] {
        quotes.sorted { a, b in
            switch (a.firstPage, b.firstPage) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.index < b.index
            }
        }
    }
}

/// Reads and writes the Markdown notes in `<Sync-Ordner>/Notes`.
/// Files are the only source of truth; changes from other Macs arrive via
/// pCloud and are picked up by polling the modification dates.
final class QuoteStore: ObservableObject {
    @Published private(set) var books: [BookNotes] = []
    @Published var errorMessage: String?

    var notesFolder: URL? {
        didSet { if notesFolder != oldValue { reload() } }
    }

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.reloadIfChanged()
        }
    }

    private func noteFiles() -> [URL] {
        guard let folder = notesFolder else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "md" }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func fallbackTitle(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Note_") { name = String(name.dropFirst(5)) }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    private func load(_ url: URL) -> BookNotes? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let doc = NoteDocument.parse(String(decoding: data, as: UTF8.self))
        return BookNotes(url: url,
                         title: doc.title ?? Self.fallbackTitle(url),
                         source: doc.source,
                         quotes: doc.quotes,
                         modified: Self.modDate(url))
    }

    func reload() {
        let loaded = noteFiles().compactMap { load($0) }
        books = loaded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func reloadIfChanged() {
        let files = noteFiles()
        if files.count != books.count { reload(); return }
        for f in files {
            guard let b = books.first(where: { $0.url == f }) else { reload(); return }
            if Self.modDate(f) != b.modified { reload(); return }
        }
    }

    // MARK: Editing

    /// Re-reads the file, finds the quote as it was loaded, applies `change`
    /// and writes the file back. Nothing else in the file is touched.
    private func modify(_ book: BookNotes, _ quote: Quote, _ change: (inout NoteDocument, Int) -> Void) -> Bool {
        guard let data = try? Data(contentsOf: book.url) else {
            errorMessage = "Die Datei konnte nicht gelesen werden."
            return false
        }
        var doc = NoteDocument.parse(String(decoding: data, as: UTF8.self))
        let matches = doc.quotes.indices.filter {
            doc.quotes[$0].text == quote.text && doc.quotes[$0].pageLabel == quote.pageLabel
        }
        guard let idx = matches.first(where: { $0 == quote.index }) ?? matches.first else {
            errorMessage = "Das Zitat wurde inzwischen an anderer Stelle geändert. Die Ansicht wurde neu geladen."
            reload()
            return false
        }
        change(&doc, idx)
        do {
            try Data(doc.render().utf8).write(to: book.url, options: .atomic)
        } catch {
            errorMessage = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return false
        }
        reload()
        return true
    }

    @discardableResult
    func update(_ book: BookNotes, _ quote: Quote, text: String, note: String) -> Bool {
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else {
            errorMessage = "Das Zitat darf nicht leer sein."
            return false
        }
        return modify(book, quote) { doc, idx in
            doc.quotes[idx].text = newText
            doc.quotes[idx].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    func delete(_ book: BookNotes, _ quote: Quote) -> Bool {
        modify(book, quote) { doc, idx in doc.quotes.remove(at: idx) }
    }

    func copy(_ quote: Quote, from book: BookNotes) {
        var s = "„\(quote.text)“ – \(book.title)"
        if let p = quote.pageLabel { s += ", \(p)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func revealInFinder(_ book: BookNotes) {
        NSWorkspace.shared.activateFileViewerSelecting([book.url])
    }
}
