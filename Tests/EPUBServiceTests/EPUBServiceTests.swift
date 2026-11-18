import AppKit
import XCTest
@testable import EPUBEdit

final class EPUBServiceTests: XCTestCase {
    @MainActor func testFinderServiceAcceptsOnlySelectedEPUBFiles() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let book = URL(fileURLWithPath: "/Example/Book.EPUB", isDirectory: false)
        let second = URL(fileURLWithPath: "/Example/Second.epub", isDirectory: false)
        XCTAssertTrue(board.writeObjects([book as NSURL, second as NSURL]))
        XCTAssertEqual(AppDelegate.epubURLs(from: board), [book, second])

        let pdf = URL(fileURLWithPath: "/Example/Notes.pdf", isDirectory: false)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([book as NSURL, pdf as NSURL]))
        XCTAssertNil(AppDelegate.epubURLs(from: board))
        board.clearContents()
        XCTAssertNil(AppDelegate.epubURLs(from: board))
        XCTAssertTrue(AppDelegate().responds(to: NSSelectorFromString("editEPUB:userData:error:")))
    }
}
