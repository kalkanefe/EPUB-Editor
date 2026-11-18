import CZlib
import Foundation

private enum ZIPError: LocalizedError {
    case invalid, unsupported, tooLarge, notEPUB, missing(String)

    var errorDescription: String? {
        switch self {
        case .invalid: return "The EPUB archive is damaged or contains conflicting file entries."
        case .unsupported: return "This EPUB uses ZIP features the editor cannot safely preserve."
        case .tooLarge: return "This EPUB exceeds the editor’s size limit."
        case .notEPUB: return "This file does not contain the EPUB media type."
        case .missing(let name): return "The EPUB is missing “\(name)”."
        }
    }
}

// Keep untouched local records, including compressed bytes and optional data descriptors.
struct EPUBArchive: Sendable {
    private static let maxArchive = 512 * 1024 * 1024
    private static let maxMember = 128 * 1024 * 1024
    private static let maxExpanded = 2 * 1024 * 1024 * 1024
    private static let mediaType = Data("application/epub+zip".utf8)

    private struct Entry: Sendable {
        let local: Range<Int>
        let payload: Range<Int>
        let central: Range<Int>
        let method: UInt16
        let expanded: Int
        let checksum: UInt32
    }

    private let bytes: Data
    private let entries: [String: Entry]
    private let comment: Data
    let names: [String]

    init(data: Data) throws {
        guard data.count <= Self.maxArchive else { throw ZIPError.tooLarge }
        let bytes = data.startIndex == 0 ? data : Data(data)
        guard bytes.count >= 22 else { throw ZIPError.invalid }
        let end = bytes.count - 22
        guard let trailer = stride(from: end, through: max(0, end - 65535), by: -1).first(where: {
            bytes.u32($0) == 0x06054b50 && Int(bytes.u16($0 + 20)) == end - $0
        }) else { throw ZIPError.invalid }

        let count = Int(bytes.u16(trailer + 10))
        guard bytes.u32(trailer + 4) == 0, Int(bytes.u16(trailer + 8)) == count,
              count < 65535 else { throw ZIPError.unsupported }
        let directory = Int(bytes.u32(trailer + 16))
        guard directory + Int(bytes.u32(trailer + 12)) == trailer else { throw ZIPError.invalid }

        var cursor = directory
        var names: [String] = []
        var entries: [String: Entry] = [:]
        var expanded = 0
        for _ in 0..<count {
            guard cursor + 46 <= trailer, bytes.u32(cursor) == 0x02014b50 else { throw ZIPError.invalid }
            let nameLength = Int(bytes.u16(cursor + 28))
            let nameRange = cursor + 46 ..< cursor + 46 + nameLength
            let next = nameRange.upperBound + Int(bytes.u16(cursor + 30)) + Int(bytes.u16(cursor + 32))
            guard next <= trailer, let name = String(data: bytes[nameRange], encoding: .utf8),
                  Self.validName(name), entries[name] == nil else { throw ZIPError.invalid }

            let flags = bytes.u16(cursor + 8)
            let method = bytes.u16(cursor + 10)
            let checksum = bytes.u32(cursor + 16)
            let compressedSize = Int(bytes.u32(cursor + 20))
            let size = Int(bytes.u32(cursor + 24))
            let fileType = bytes.u32(cursor + 38) >> 28
            guard [UInt16(0), 8].contains(method), flags & ~0x080e == 0,
                  bytes.u16(cursor + 34) == 0, [0, 4, 8].contains(fileType) else { throw ZIPError.unsupported }
            expanded += size
            guard size <= Self.maxMember, expanded <= Self.maxExpanded else { throw ZIPError.tooLarge }
            guard method != 0 || compressedSize == size else { throw ZIPError.invalid }

            let local = Int(bytes.u32(cursor + 42))
            guard local + 30 <= directory, bytes.u32(local) == 0x04034b50,
                  bytes.u16(local + 6) == flags, bytes.u16(local + 8) == method,
                  Int(bytes.u16(local + 26)) == nameLength else { throw ZIPError.invalid }
            let localName = local + 30 ..< local + 30 + nameLength
            let start = localName.upperBound + Int(bytes.u16(local + 28))
            let payload = start ..< start + compressedSize
            guard payload.upperBound <= directory, bytes[localName] == bytes[nameRange] else { throw ZIPError.invalid }
            var localEnd = payload.upperBound
            if flags & 8 != 0 {
                // An optional signature precedes the CRC, compressed size and original size.
                if localEnd + 16 <= directory, bytes.u32(localEnd) == 0x08074b50,
                   bytes.u32(localEnd + 4) == checksum { localEnd += 4 }
                guard localEnd + 12 <= directory, bytes.u32(localEnd) == checksum,
                      Int(bytes.u32(localEnd + 4)) == compressedSize,
                      Int(bytes.u32(localEnd + 8)) == size else { throw ZIPError.invalid }
                localEnd += 12
            } else {
                guard bytes.u32(local + 14) == checksum, Int(bytes.u32(local + 18)) == compressedSize,
                      Int(bytes.u32(local + 22)) == size else { throw ZIPError.invalid }
            }
            entries[name] = Entry(local: local..<localEnd, payload: payload, central: cursor..<next,
                                  method: method, expanded: size, checksum: checksum)
            names.append(name)
            cursor = next
        }
        guard cursor == trailer else { throw ZIPError.invalid }
        let records = entries.values.map(\.local).sorted { $0.lowerBound < $1.lowerBound }
        var endOfRecords = 0
        for range in records {
            guard range.lowerBound == endOfRecords else { throw ZIPError.invalid }
            endOfRecords = range.upperBound
        }
        guard endOfRecords == directory else { throw ZIPError.invalid }
        self.bytes = bytes
        self.entries = entries
        self.names = names
        self.comment = Data(bytes[(trailer + 22)...])
        guard entries["mimetype"]?.expanded == Self.mediaType.count,
              try self.data(for: "mimetype") == Self.mediaType else { throw ZIPError.notEPUB }
    }

    var needsMimetypeRepair: Bool {
        guard let mime = entries["mimetype"] else { return true }
        return mime.local.lowerBound != 0 || mime.method != 0 || bytes.u16(28) != 0 || bytes.u16(6) & 8 != 0
    }

    func expandedSize(of name: String) -> Int? { entries[name]?.expanded }

    func data(for name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZIPError.missing(name) }
        let result: Data
        if entry.method == 0 {
            result = Data(bytes[entry.payload])
        } else {
            let capacity = max(1, entry.expanded)
            var output = Data(count: capacity)
            let success = output.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { source in
                    epub_inflate(source.bindMemory(to: UInt8.self).baseAddress! + entry.payload.lowerBound,
                                 UInt32(entry.payload.count), destination.bindMemory(to: UInt8.self).baseAddress,
                                 UInt32(capacity), UInt32(entry.expanded))
                }
            }
            guard success != 0 else { throw ZIPError.invalid }
            output.count = entry.expanded
            result = output
        }
        guard result.zipCRC == entry.checksum else { throw ZIPError.invalid }
        return result
    }

    func replacing(_ updates: [String: Data]) throws -> Data {
        var changes = updates
        guard changes["mimetype"].map({ $0 == Self.mediaType }) ?? true else { throw ZIPError.notEPUB }
        guard changes.keys.allSatisfy({ Self.validName($0) && !$0.hasSuffix("/") }) else { throw ZIPError.invalid }
        changes["mimetype"] = Self.mediaType
        let added = changes.keys.filter { entries[$0] == nil }.sorted()
        let order = ["mimetype"] + names.filter { $0 != "mimetype" } + added
        guard order.count < 65535 else { throw ZIPError.tooLarge }
        var expanded = 0
        var output = Data()
        var directory = Data()
        for name in order {
            let offset = UInt32(output.count)
            let original = entries[name]
            let size = changes[name]?.count ?? original!.expanded
            expanded += size
            guard size <= Self.maxMember, expanded <= Self.maxExpanded else { throw ZIPError.tooLarge }
            if let content = changes[name] {
                let dateTime = original.map { bytes.u32($0.central.lowerBound + 12) } ?? 0x00210000
                Self.append(name: name, content: content, dateTime: dateTime, to: &output, directory: &directory)
            } else if let original {
                output.append(bytes[original.local])
                let record = original.central
                directory.append(bytes[record.lowerBound..<record.lowerBound + 42])
                directory.put(offset)
                directory.append(bytes[record.lowerBound + 46..<record.upperBound])
            }
            guard output.count + directory.count <= Self.maxArchive else { throw ZIPError.tooLarge }
        }
        let centralOffset = UInt32(output.count)
        output.append(directory)
        output.put(UInt32(0x06054b50))
        output.put(UInt32(0))
        output.put(UInt16(order.count))
        output.put(UInt16(order.count))
        output.put(UInt32(directory.count))
        output.put(centralOffset)
        output.put(UInt16(comment.count))
        output.append(comment)
        guard output.count <= Self.maxArchive else { throw ZIPError.tooLarge }
        return output
    }

    private static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 65535, !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let path = name.hasSuffix("/") ? name.dropLast() : name[...]
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func append(name: String, content: Data, dateTime: UInt32, to output: inout Data, directory: inout Data) {
        let nameBytes = Data(name.utf8)
        let offset = UInt32(output.count)
        var payload = content
        var method: UInt16 = 0
        if content.count >= 128 {
            // A compressed member is only worthwhile if it fits in fewer bytes than the original.
            let capacity = UInt32(content.count - 1)
            var compressed = Data(count: Int(capacity))
            let count = compressed.withUnsafeMutableBytes { destination in
                content.withUnsafeBytes { source in
                    epub_deflate(source.bindMemory(to: UInt8.self).baseAddress, UInt32(content.count),
                                 destination.bindMemory(to: UInt8.self).baseAddress, capacity)
                }
            }
            if count > 0 {
                compressed.count = Int(count)
                payload = compressed
                method = 8
            }
        }
        var fields = Data()
        fields.put(UInt16(20))
        fields.put(UInt16(0x0800))
        fields.put(method)
        fields.put(dateTime)
        fields.put(content.zipCRC)
        fields.put(UInt32(payload.count))
        fields.put(UInt32(content.count))
        fields.put(UInt16(nameBytes.count))
        fields.put(UInt16(0))     // extra length
        output.put(UInt32(0x04034b50))
        output.append(fields)
        output.append(nameBytes)
        output.append(payload)
        directory.put(UInt32(0x02014b50))
        directory.put(UInt16(20))
        directory.append(fields)
        directory.put(UInt16(0)) // comment length
        directory.put(UInt16(0)) // disk number
        directory.put(UInt16(0)) // internal attributes
        directory.put(UInt32(0)) // external attributes
        directory.put(offset)
        directory.append(nameBytes)
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func u32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    mutating func put<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    var zipCRC: UInt32 {
        withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(count))) }
    }
}
