import Foundation
import EPUBCore

struct KindleExportNotice: Sendable {
    let title: String
    let detail: String
    var file: URL? = nil

    static func make(book: EPUBBook, edits: BookMetadata, cover: Data?, source: URL) throws -> Self {
        let current: EPUBBook
        if edits != book.metadata || cover != nil {
            current = try EPUBBook(data: book.writing(metadata: edits, replacementCover: cover))
        } else {
            current = book
        }
        let repair = try current.repairingForKindle()
        var summary: [String] = []
        if repair.stylesFixed > 0 {
            summary.append(repair.stylesFixed == 1 ? "Adjusted 1 fixed size in the book’s styles." :
                           "Adjusted \(repair.stylesFixed) fixed sizes in the book’s styles.")
        }
        if repair.stylesheetLinksCreated > 0 {
            summary.append("Consolidated \(repair.stylesheetLinksCreated) repeated style blocks.")
        }
        if repair.containerFixed {
            summary.append("Corrected the EPUB file header.")
        }
        if repair.skippedResources > 0 {
            summary.append(repair.skippedResources == 1 ? "Skipped 1 resource that couldn’t be safely processed." :
                           "Skipped \(repair.skippedResources) resources that couldn’t be safely processed.")
        }
        guard repair.changed else {
            return Self(title: "No Kindle fixes applied.",
                        detail: summary.isEmpty ? "These checks found no changes to make." : summary.joined(separator: " "))
        }
        let file = try writeCopy(repair.data, beside: source)
        return Self(title: "Created “\(file.lastPathComponent)”.", detail: summary.joined(separator: " "), file: file)
    }

    private static func writeCopy(_ data: Data, beside source: URL) throws -> URL {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: source, create: true)
        defer { try? fm.removeItem(at: staging) }
        let complete = staging.appendingPathComponent("Kindle.epub")
        try data.write(to: complete)

        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let suffix = number == 1 ? " (Kindle).epub" : " (Kindle \(number)).epub"
            var name = stem
            while name.utf8.count + suffix.utf8.count > Int(NAME_MAX) { name.removeLast() }
            let destination = directory.appendingPathComponent(name + suffix)
            do {
                // Move a complete file into place. Existing editions keep their names and contents.
                try fm.moveItem(at: complete, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }
}
