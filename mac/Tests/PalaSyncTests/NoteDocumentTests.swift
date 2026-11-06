import XCTest
@testable import PalaSync

final class NoteDocumentTests: XCTestCase {
    // Exactly what tools/sync_books.py writes (header + appended quotes).
    let syncFile = """
    # 📝 Zitate: Der Steppenwolf
    **Quelle:** `Der_Steppenwolf.txt`  
    **Zuletzt aktualisiert:** 06.11.2026 um 17:10 Uhr  
    **Anzahl Zitate:** 2

    ---

    ## 📌 Wichtige Zitate

    > "Ein alter Satz."
    *(Seite 12)*

    Meine Notiz dazu, **wichtig**.

    > "Neuer Satz eins. Und zwei."
    *(Seiten 40–41)*

    """

    func testParsesSyncFile() {
        let doc = NoteDocument.parse(syncFile)
        XCTAssertEqual(doc.title, "Der Steppenwolf")
        XCTAssertEqual(doc.source, "Der_Steppenwolf.txt")
        XCTAssertEqual(doc.quotes.count, 2)
        XCTAssertEqual(doc.quotes[0].text, "Ein alter Satz.")
        XCTAssertEqual(doc.quotes[0].pageLabel, "Seite 12")
        XCTAssertEqual(doc.quotes[0].note, "Meine Notiz dazu, **wichtig**.")
        XCTAssertEqual(doc.quotes[0].firstPage, 12)
        XCTAssertEqual(doc.quotes[1].text, "Neuer Satz eins. Und zwei.")
        XCTAssertEqual(doc.quotes[1].note, "")
        XCTAssertEqual(doc.quotes[1].firstPage, 40)
    }

    func testRoundTripKeepsFileUnchanged() {
        XCTAssertEqual(NoteDocument.parse(syncFile).render(), syncFile)
    }

    func testEditMultilineQuoteAndNote() {
        var doc = NoteDocument.parse(syncFile)
        doc.quotes[1].text = "Erster Absatz.\n\nZweiter Absatz."
        doc.quotes[1].note = "> kein Zitat\nZeile zwei"
        let again = NoteDocument.parse(doc.render())
        XCTAssertEqual(again.quotes.count, 2)
        XCTAssertEqual(again.quotes[1].text, "Erster Absatz.\n\nZweiter Absatz.")
        XCTAssertEqual(again.quotes[1].note, "> kein Zitat\nZeile zwei")
        XCTAssertEqual(again.quotes[0].note, "Meine Notiz dazu, **wichtig**.")
    }

    func testDeleteUpdatesCount() {
        var doc = NoteDocument.parse(syncFile)
        doc.quotes.remove(at: 0)
        let out = doc.render()
        XCTAssertTrue(out.contains("**Anzahl Zitate:** 1"))
        XCTAssertFalse(out.contains("Ein alter Satz."))
        XCTAssertTrue(out.contains("**Zuletzt aktualisiert:** 06.11.2026 um 17:10 Uhr  "))
    }

    func testOldFormatWithoutTrailingNewline() {
        let doc = NoteDocument.parse("# 📝 Zitate: X\n\n> \"A\"\n*(Seite 1)*\n> \"B\"\n*(Seite 2)*")
        XCTAssertEqual(doc.quotes.map(\.text), ["A", "B"])
        XCTAssertEqual(doc.quotes.map(\.note), ["", ""])
    }
}
