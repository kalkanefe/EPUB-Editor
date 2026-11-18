import Foundation
import ImageIO
import XCTest
@testable import EPUBCore

final class BookTests: XCTestCase {
    private let seed = Data(base64Encoded: "UEsDBBQAAAAAAK0Gcl1vYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAQIUAxQAAAAAAK0Gcl1vYassFAAAABQAAAAIAAAAAAAAAAAAAACAAQAAAABtaW1ldHlwZVBLBQYAAAAAAQABADYAAAA6AAAAAAA=")!
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPgkjEAAACKAFfBDQtlAAAAAElFTkSuQmCC")!
    private let path = "Books/Package/content.opf"
    private let chapterPath = "Books/Text/Chapter One.xhtml"
    private let chapter = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter One</title><style type="text/css">p { color: teal; }</style></head>
    <body><p>A&nbsp;chapter &amp; text with <em>emphasis</em>.</p></body></html>
    """
    private func fixture(version: String = "3.0", extra: String = "", extraItems: String = "") throws -> Data {
        let container = """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="\(path)" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let package = """
        <!DOCTYPE package>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:d="http://purl.org/dc/elements/1.1/" version="\(version)" unique-identifier="uuid">
        <metadata><d:identifier id="uuid">9781234567890</d:identifier><d:title>Original</d:title><d:creator>A</d:creator><d:creator>B &amp; C</d:creator>
        <d:language>en</d:language>\(extra)</metadata>
        <manifest><item id="one" href="../Text/Chapter%20One.xhtml" media-type="application/xhtml+xml"/>\(extraItems)</manifest>
        <spine><itemref idref="one"/></spine></package>
        """
        return try EPUBArchive(data: seed).replacing([
            "META-INF/container.xml": Data(container.utf8), path: Data(package.utf8), chapterPath: Data(chapter.utf8)
        ])
    }

    func testMetadataAndNestedPathsRoundTrip() throws {
        let original = try fixture()
        let book = try EPUBBook(data: original)
        XCTAssertEqual(try book.writing(metadata: book.metadata, replacementCover: nil), original)
        var edit = book.metadata
        edit.title = "A & B < C"
        edit.publisher = "Printer & Son"
        let saved = try book.writing(metadata: edit, replacementCover: nil)
        let reread = try EPUBBook(data: saved)
        XCTAssertEqual(reread.metadata, edit)
        let zip = try EPUBArchive(data: saved)
        XCTAssertEqual(try zip.data(for: chapterPath), Data(chapter.utf8))
        let doc = try XMLDocument(data: zip.data(for: path))
        XCTAssertEqual(doc.dtd?.name, "package")
        XCTAssertEqual(try doc.nodes(forXPath: "//*[local-name()='creator']").compactMap(\.stringValue), ["A", "B & C"])
        XCTAssertEqual(try doc.nodes(forXPath: "//*[local-name()='identifier']").first?.stringValue, "9781234567890")
        XCTAssertEqual(try doc.nodes(forXPath: "//*[@property='dcterms:modified']").count, 1)
    }

    func testTypographyAndPublisherReset() throws {
        let book = try EPUBBook(data: fixture())
        XCTAssertTrue(book.allowsFormatting)
        var edit = book.metadata
        edit.font = .sansSerif
        edit.lineSpacing = .comfortable
        let saved = try book.writing(metadata: edit, replacementCover: nil)
        let reread = try EPUBBook(data: saved)
        XCTAssertEqual(reread.metadata, edit)
        let reset = try reread.writing(metadata: book.metadata, replacementCover: nil)
        let zip = try EPUBArchive(data: reset)
        XCTAssertEqual(try zip.data(for: chapterPath), Data(chapter.utf8))
        let content = try XMLDocument(data: zip.data(for: chapterPath), options: .nodeLoadExternalEntitiesNever)
        XCTAssertEqual(try content.nodes(forXPath: "//*[local-name()='style']").compactMap(\.stringValue), ["p { color: teal; }"])
        XCTAssertEqual(try content.nodes(forXPath: "//*[local-name()='em']").first?.stringValue, "emphasis")
        XCTAssertEqual(try EPUBBook(data: reset).metadata, book.metadata)
    }

    func testCoverRegistrationInBothFormatsAndExistingNestedCover() throws {
        for version in ["2.0", "3.0"] {
            let book = try EPUBBook(data: fixture(version: version))
            let saved = try book.writing(metadata: book.metadata, replacementCover: png)
            XCTAssertEqual(try EPUBBook(data: saved).coverData, png)
            let zip = try EPUBArchive(data: saved)
            XCTAssertEqual(try zip.data(for: "Books/Package/nativeepub-cover.png"), png)
            let doc = try XMLDocument(data: zip.data(for: path))
            let registration = version == "2.0" ? "//*[@name='cover' and @content='nativeepub-cover']" : "//*[@properties='cover-image']"
            XCTAssertEqual(try doc.nodes(forXPath: registration).count, 1)
        }
        let original = try fixture(extraItems: "<item id='jacket' properties='cover-image' href='../Art/Jacket%20Art.jpg' media-type='image/jpeg'/>")
        let book = try EPUBBook(data: original)
        let saved = try book.writing(metadata: book.metadata, replacementCover: png)
        let zip = try EPUBArchive(data: saved)
        let cover = try zip.data(for: "Books/Art/Jacket Art.jpg")
        XCTAssertEqual(try EPUBBook(data: saved).coverData, cover)
        XCTAssertTrue(cover.starts(with: [0xFF, 0xD8]))
    }

    func testFixedLayoutAndSignedContainer() throws {
        let original = try fixture(extra: "<meta property='rendition:layout'>pre-paginated</meta>")
        let book = try EPUBBook(data: original)
        XCTAssertFalse(book.allowsFormatting)
        var edit = book.metadata
        edit.lineSpacing = .spacious
        XCTAssertThrowsError(try book.writing(metadata: edit, replacementCover: nil))
        let signed = try EPUBArchive(data: original).replacing(["META-INF/signatures.xml": Data()])
        XCTAssertThrowsError(try EPUBBook(data: signed))
    }
}
