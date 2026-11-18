import Foundation
import XCTest
@testable import EPUBCore

final class KindleRepairTests: XCTestCase {
    private let seed = Data(base64Encoded: "UEsDBBQAAAAAAK0Gcl1vYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAQIUAxQAAAAAAK0Gcl1vYassFAAAABQAAAAIAAAAAAAAAAAAAACAAQAAAABtaW1ldHlwZVBLBQYAAAAAAQABADYAAAA6AAAAAAA=")!
    private let opf = "My Book/package.opf"
    private let paths = ["Text/First.xhtml", "Sections/Two/Second.xhtml"]
    private let sheet = "p, li { font-size: 11pt; width: 12px; } .prose {font-size: 16pt} h1 { font-size: 24pt }"
    private let body = "<h1 id='h'>Title</h1><p><span class='prose'>First &amp; <em>more</em>.</span></p><p><span class='prose'>Second.</span></p>"
    private let external = "body {width: 800px; height: 900px} p {line-height: 18px !important} @media print { p {font-size:12pt} } .q { content:'}p{font-size:20px;'; height:8px }"

    private func fixture(css: String, body: String, extraMeta: String = "", external: String = "") throws -> Data {
        let container = "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='\(opf)'/></rootfiles></container>"
        let items = paths.enumerated().map { "<item id='ch\($0)' href='../\($1)' media-type='application/xhtml+xml'/>" }.joined()
        let spine = "<itemref idref='ch0'/><itemref idref='ch1'/>"
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="u">
        <metadata><dc:identifier id="u">id</dc:identifier><dc:language>en</dc:language><dc:title>Some Book</dc:title>\(extraMeta)</metadata>
        <manifest>\(items)<item id="epub-edit-kindle-1" href="taken.css" media-type="text/css"/><item id="art" href="art.png" media-type="image/png"/></manifest>
        <spine>\(spine)</spine></package>
        """
        var resources = ["META-INF/container.xml": Data(container.utf8), opf: Data(package.utf8),
                         "My Book/taken.css": Data(external.utf8), "My Book/art.png": Data([1, 2, 3])]
        for path in paths {
            let doc = "<!DOCTYPE html><html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter</title><style type='text/css'>\(css)</style></head><body>\(body)</body></html>"
            resources[path] = Data(doc.utf8)
        }
        return try EPUBArchive(data: seed).replacing(resources)
    }

    func testProseReflowSharedStylesAndByteIdenticalSecondPass() throws {
        let input = try fixture(css: sheet, body: body, external: external)
        let result = try EPUBBook(data: input).repairingForKindle()
        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.containerFixed)
        XCTAssertEqual(result.stylesFixed, 7)
        XCTAssertEqual(result.stylesheetLinksCreated, 2)
        XCTAssertEqual(result.skippedResources, 0)
        let archive = try EPUBArchive(data: result.data)
        let key = "My Book/epub-edit-kindle-2.css"
        let css = String(decoding: try archive.data(for: key), as: UTF8.self)
        XCTAssertEqual(css, "p, li { font-size: 1em; width: 12px; } .prose {font-size: 1em} h1 { font-size: 24pt }")
        XCTAssertEqual(String(decoding: try archive.data(for: "My Book/taken.css"), as: UTF8.self),
                       external.replacingOccurrences(of: "800px", with: "auto").replacingOccurrences(of: "900px", with: "auto").replacingOccurrences(of: "18px", with: "normal"))
        for path in paths {
            let data = try archive.data(for: path)
            let raw = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(raw.contains(body))
            XCTAssertTrue(raw.hasPrefix("<!DOCTYPE html>"))
            let doc = try XMLDocument(data: data)
            let href = try XCTUnwrap(doc.nodes(forXPath: "//*[local-name()='link']/@href").first?.stringValue)
            XCTAssertTrue(href.contains("My%20Book"))
            XCTAssertEqual(try resourcePath(href, relativeTo: path), key)
        }
        let package = try XMLDocument(data: archive.data(for: opf))
        XCTAssertEqual(try package.nodes(forXPath: "//*[local-name()='item' and @id='epub-edit-kindle-2' and @media-type='text/css']").count, 1)
        XCTAssertEqual(try archive.data(for: "My Book/art.png"), Data([1, 2, 3]))
        let reopened = try EPUBBook(data: result.data)
        XCTAssertEqual(reopened.metadata, try EPUBBook(data: input).metadata)
        let repeated = try reopened.repairingForKindle()
        XCTAssertFalse(repeated.changed)
        XCTAssertEqual(repeated.data, result.data)
    }

    func testAmbiguityRelativeURLsAndFixedLayouts() throws {
        let ambiguous = body.replacingOccurrences(of: ">Title</h1>", with: "><span class='prose'>Title</span></h1>")
        let css = ".prose {font-size: 14pt} p {background-image: url('../img.jpg'); font-size: 95%}"
        let source = try fixture(css: css, body: ambiguous)
        let result = try EPUBBook(data: source).repairingForKindle()
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, source)
        for meta in ["<meta property='rendition:layout'>pre-paginated</meta>", "<meta name='fixed-layout' content='true'/>"] {
            XCTAssertThrowsError(try EPUBBook(data: fixture(css: sheet, body: body, extraMeta: meta)).repairingForKindle())
        }
        let changedArchive = try EPUBArchive(data: source).replacing([paths[1]: Data("<not-xhtml/>".utf8)])
        let skipped = try EPUBBook(data: changedArchive).repairingForKindle()
        XCTAssertEqual(skipped.skippedResources, 1)
        XCTAssertEqual(skipped.data, changedArchive)
    }

    func testCSSWithRelativeImageSetCSPOrDistinctUnicodeStaysInline() throws {
        let css = "p { background-image: image-set('../paper.png' 1x) }"
        let input = try fixture(css: css, body: body)
        XCTAssertEqual(try EPUBBook(data: input).repairingForKindle().data, input)

        let cleanSheet = "h2::before { content: 'caf\u{e9}' }"
        let archive = try EPUBArchive(data: fixture(css: cleanSheet, body: body))
        let second = String(decoding: try archive.data(for: paths[1]), as: UTF8.self)
        let distinct = try archive.replacing([paths[1]: Data(second.replacingOccurrences(of: "é", with: "e\u{301}").utf8)])
        XCTAssertEqual(try EPUBBook(data: distinct).repairingForKindle().data, distinct)

        let protected = second.replacingOccurrences(of: "<head>", with: "<head><meta http-equiv='Content-Security-Policy' content=\"style-src 'unsafe-inline'\"/>")
        let csp = try archive.replacing([paths[1]: Data(protected.utf8)])
        let result = try EPUBBook(data: csp).repairingForKindle()
        XCTAssertEqual(result.skippedResources, 1)
        XCTAssertEqual(result.data, csp)
    }

    func testMimetypeIsRepairedEvenWhenTheBookHasNoStyleChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(css: "p { margin: 0; background-image:url(bg.jpg) }", body: body)
        let zip = try EPUBArchive(data: source)
        for name in zip.names {
            let path = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.data(for: name).write(to: path)
        }
        let command = Process()
        command.currentDirectoryURL = directory
        command.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        command.arguments = ["-q", "misordered.epub"] + zip.names.filter { $0 != "mimetype" } + ["mimetype"]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        let bad = try Data(contentsOf: directory.appendingPathComponent("misordered.epub"))
        let result = try EPUBBook(data: bad).repairingForKindle()
        XCTAssertTrue(result.containerFixed)
        XCTAssertEqual(result.stylesFixed, 0)
        XCTAssertEqual(result.stylesheetLinksCreated, 0)
        XCTAssertFalse(try EPUBArchive(data: result.data).needsMimetypeRepair)
        XCTAssertEqual(try EPUBBook(data: result.data).repairingForKindle().data, result.data)
    }
}
