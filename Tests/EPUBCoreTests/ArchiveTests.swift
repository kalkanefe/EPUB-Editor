import Foundation
import XCTest
@testable import EPUBCore

final class ArchiveTests: XCTestCase {
    func testEditsRoundTripThroughSystemUnzip() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let mime = Data("application/epub+zip".utf8)
        let chapter = Data(String(repeating: "Chapter text. ", count: 1000).utf8)
        let revised = Data(String(repeating: "A revised title. ", count: 100).utf8)
        let cover = Data([0, 255, 0, 147, 72])
        try mime.write(to: temporary.appendingPathComponent("mimetype"))
        try chapter.write(to: temporary.appendingPathComponent("chapter.xhtml"))
        try Data("old".utf8).write(to: temporary.appendingPathComponent("book.opf"))
        try run("/usr/bin/zip", ["-q0X", "book.epub", "mimetype"], in: temporary)
        try run("/usr/bin/zip", ["-q9X", "book.epub", "chapter.xhtml", "book.opf"], in: temporary)

        let input = try Data(contentsOf: temporary.appendingPathComponent("book.epub"))
        let archive = try EPUBArchive(data: input)
        let saved = try archive.replacing(["book.opf": revised, "images/new.jpg": cover])
        try saved.write(to: temporary.appendingPathComponent("edited.epub"))
        try run("/usr/bin/unzip", ["-tq", "edited.epub"], in: temporary)

        let reopened = try EPUBArchive(data: saved)
        XCTAssertEqual(reopened.names.first, "mimetype")
        XCTAssertEqual(saved[8..<10], Data([0, 0]))
        XCTAssertEqual(saved[28..<30], Data([0, 0]))
        XCTAssertEqual(saved[30..<38], Data("mimetype".utf8))
        XCTAssertEqual(try reopened.data(for: "chapter.xhtml"), chapter)
        XCTAssertEqual(try reopened.data(for: "book.opf"), revised)
        XCTAssertEqual(try reopened.data(for: "images/new.jpg"), cover)
        XCTAssertThrowsError(try reopened.data(for: "missing"))
        XCTAssertThrowsError(try archive.replacing(["../escape": cover]))

        var damaged = saved
        let offset = try XCTUnwrap(damaged.range(of: cover)?.lowerBound)
        damaged[offset] ^= 0xff
        XCTAssertThrowsError(try EPUBArchive(data: damaged).data(for: "images/new.jpg"))
        XCTAssertThrowsError(try EPUBArchive(data: Data(saved.dropLast())))
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
