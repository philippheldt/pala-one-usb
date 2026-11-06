import SwiftUI
import AppKit

enum QuotesWindow {
    private static var window: NSWindow?

    static func show(store: QuoteStore) {
        store.reload()
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Zitate"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: QuotesView().environmentObject(store))
            w.setFrameAutosaveName("PalaQuotesWindow")
            if !w.setFrameUsingName("PalaQuotesWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct QuotesView: View {
    @EnvironmentObject var store: QuoteStore
    @State private var selection: URL?
    @State private var search = ""

    private var selectedBook: BookNotes? {
        store.books.first { $0.url == selection } ?? store.books.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .alert("Hinweis", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("In allen Zitaten suchen", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(10)

            List(store.books, selection: $selection) { book in
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(.body, design: .serif))
                        .lineLimit(2)
                    Text(book.quotes.count == 1 ? "1 Zitat" : "\(book.quotes.count) Zitate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(book.url)
                .contextMenu {
                    Button("Im Finder zeigen") { store.revealInFinder(book) }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if store.books.isEmpty {
            EmptyStateView(
                title: "Noch keine Zitate",
                message: store.notesFolder == nil
                    ? "Wähle zuerst einen Sync-Ordner."
                    : "Halte beim Lesen die Taste lange gedrückt, um eine Seite als Zitat zu speichern. Nach dem nächsten Sync erscheint sie hier."
            )
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(query: search.trimmingCharacters(in: .whitespaces))
        } else if let book = selectedBook {
            BookQuotesView(book: book)
                .id(book.url)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(.title2, design: .serif))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .padding(40)
    }
}

struct BookQuotesView: View {
    let book: BookNotes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .textSelection(.enabled)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                if book.quotes.isEmpty {
                    Text("Keine Zitate in dieser Datei.").foregroundStyle(.secondary)
                }
                ForEach(book.sortedQuotes) { quote in
                    QuoteCard(book: book, quote: quote)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var subtitle: String {
        let n = book.quotes.count
        var s = n == 1 ? "1 Zitat" : "\(n) Zitate"
        let withNotes = book.quotes.filter { !$0.note.isEmpty }.count
        if withNotes > 0 { s += " · \(withNotes) mit Notiz" }
        return s
    }
}

struct SearchResultsView: View {
    @EnvironmentObject var store: QuoteStore
    let query: String

    private var results: [(BookNotes, [Quote])] {
        store.books.compactMap { book in
            let hits = book.sortedQuotes.filter {
                $0.text.localizedCaseInsensitiveContains(query) ||
                $0.note.localizedCaseInsensitiveContains(query)
            }
            return hits.isEmpty ? nil : (book, hits)
        }
    }

    var body: some View {
        let res = results
        if res.isEmpty {
            EmptyStateView(title: "Nichts gefunden", message: "Kein Zitat und keine Notiz enthält „\(query)“.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(res, id: \.0.url) { book, quotes in
                        Text(book.title)
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .padding(.top, 12)
                        ForEach(quotes) { quote in
                            QuoteCard(book: book, quote: quote)
                        }
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 30)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct QuoteCard: View {
    @EnvironmentObject var store: QuoteStore
    let book: BookNotes
    let quote: Quote

    @State private var editing = false
    @State private var draftText = ""
    @State private var draftNote = ""
    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if editing { editor } else { display }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(hovering && !editing ? 0.08 : 0.04), radius: hovering ? 8 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(editing ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .confirmationDialog("Dieses Zitat löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { store.delete(book, quote) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Das Zitat und seine Notiz werden aus der Datei entfernt.")
        }
    }

    // MARK: Display (no Markdown characters visible)

    private var display: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("„")
                .font(.system(size: 44, weight: .regular, design: .serif))
                .foregroundStyle(Color.accentColor.opacity(0.55))
                .frame(width: 22, alignment: .leading)
                .offset(y: -6)

            VStack(alignment: .leading, spacing: 12) {
                Text(quote.text)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if let page = quote.pageLabel {
                        Text(page.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actions
                        .opacity(hovering ? 1 : 0)
                }

                if !quote.note.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text(Self.renderNote(quote.note))
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.07)))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startEditing() }
        .contextMenu { menuItems }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { startEditing() } label: {
                Label(quote.note.isEmpty ? "Notiz" : "Bearbeiten",
                      systemImage: quote.note.isEmpty ? "square.and.pencil" : "pencil")
            }
            .buttonStyle(.borderless)
            .help("Zitat und Notiz bearbeiten (Doppelklick)")

            Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .font(.caption)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Bearbeiten") { startEditing() }
        Button("Zitat kopieren") { store.copy(quote, from: book) }
        Divider()
        Button("Löschen …", role: .destructive) { confirmDelete = true }
    }

    static func renderNote(_ note: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: note, options: options)) ?? AttributedString(note)
    }

    // MARK: Editing (plain text, Markdown only here)

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Zitat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let page = quote.pageLabel {
                    Text(page).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $draftText)
                .font(.system(size: 15, design: .serif))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            Text("Notiz").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            TextEditor(text: $draftNote)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 70)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text("Tipp: **fett** und *kursiv* funktionieren in der Notiz.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Abbrechen") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    if store.update(book, quote, text: draftText, note: draftNote) {
                        editing = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private func startEditing() {
        draftText = quote.text
        draftNote = quote.note
        editing = true
    }
}
