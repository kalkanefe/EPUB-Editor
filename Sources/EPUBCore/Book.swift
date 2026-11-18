import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BookFont: String, CaseIterable, Sendable { case original, serif, sansSerif }
public enum BookLineSpacing: String, CaseIterable, Sendable { case original, comfortable, spacious }

public struct BookMetadata: Equatable, Sendable {
    public var title = ""
    public var author = ""
    public var language = ""
    public var publisher = ""
    public var description = ""
    public var font: BookFont = .original
    public var lineSpacing: BookLineSpacing = .original

    public init() {}
}

private let opf = "http://www.idpf.org/2007/opf"
private let dc = "http://purl.org/dc/elements/1.1/"
private let xhtml = "http://www.w3.org/1999/xhtml"
private let fields: [(String, WritableKeyPath<BookMetadata, String>)] = [
    ("title", \.title), ("creator", \.author), ("language", \.language),
    ("publisher", \.publisher), ("description", \.description)
]

struct BookIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension XMLElement {
    func elements(_ name: String, _ namespace: String) -> [XMLElement] {
        elements(forLocalName: name, uri: namespace)
    }

    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }

    func setAttr(_ name: String, _ value: String) {
        if let attribute = attribute(forName: name) { attribute.stringValue = value }
        else { addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }

    func append(_ name: String, namespace: String) -> XMLElement {
        let prefix = resolvePrefix(forNamespaceURI: namespace)
        let child = XMLElement(name: prefix.flatMap { $0.isEmpty ? nil : $0 + ":" + name } ?? name,
                               uri: namespace)
        addChild(child)
        return child
    }
}

func parsedXML(_ data: Data) throws -> XMLDocument {
    guard data.count <= 24 * 1024 * 1024 else { throw BookIssue("An XML document in this book is too large to edit.") }
    let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    guard let source = String(data: data, encoding: isUTF16 ? .utf16 : .utf8),
          !source.contains("\0"), !source.contains("<!ENTITY") else {
        throw BookIssue("This book contains an unsupported XML encoding or entity declaration.")
    }
    let document = try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
    document.documentContentKind = .xml
    return document
}

// EPUB hrefs are URL references, while ZIP entries are decoded, case-sensitive paths.
func resourcePath(_ href: String, relativeTo file: String) throws -> String {
    let relative = href.prefix { $0 != "#" && $0 != "?" }
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), URLComponents(string: String(relative))?.scheme == nil else {
        throw BookIssue("This book references a resource outside its EPUB archive.")
    }
    var parts = file.split(separator: "/").dropLast().map(String.init)
    for component in relative.split(separator: "/") {
        guard let decoded = component.removingPercentEncoding, !decoded.contains("/"),
              !decoded.contains("\\"), !decoded.contains("\0") else { throw BookIssue("A resource path in this EPUB is invalid.") }
        if decoded == ".." {
            guard !parts.isEmpty else { throw BookIssue("A resource path leaves the EPUB archive.") }
            parts.removeLast()
        } else if decoded != "." {
            parts.append(decoded)
        }
    }
    guard !parts.isEmpty else { throw BookIssue("This EPUB has an empty resource path.") }
    return parts.joined(separator: "/")
}

struct Package {
    let document: XMLDocument
    let metadata: XMLElement
    let manifest: XMLElement
    let spine: XMLElement
    let version: String

    init(data: Data) throws {
        document = try parsedXML(data)
        if document.dtd != nil {
            let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
            let source = String(data: data, encoding: encoding) ?? ""
            if source.range(of: #"&(?!amp;|lt;|gt;|apos;|quot;)[A-Za-z_:][A-Za-z0-9_.:-]*;"#, options: .regularExpression) != nil {
                throw BookIssue("The package document uses external entities that cannot be edited safely.")
            }
        }
        guard let root = document.rootElement(), root.localName == "package", root.uri == opf,
              let metadata = root.elements("metadata", opf).first,
              let manifest = root.elements("manifest", opf).first, let spine = root.elements("spine", opf).first,
              let version = root.attr("version"), ["2", "3"].contains(version.split(separator: ".").first) else {
            throw BookIssue("This file needs a valid EPUB 2 or EPUB 3 package.")
        }
        guard try document.nodes(forXPath: "//*[@xml:base]").isEmpty else {
            throw BookIssue("This EPUB uses custom base paths that this editor cannot preserve.")
        }
        self.metadata = metadata
        self.manifest = manifest
        self.spine = spine
        self.version = version
    }

    var metas: [XMLElement] { metadata.elements("meta", opf) }
    var items: [XMLElement] { manifest.elements("item", opf) }

    var coverItem: XMLElement? {
        if let primary = items.first(where: { $0.attr("properties")?.split(whereSeparator: \.isWhitespace).contains("cover-image") == true }) {
            return primary
        }
        guard let legacy = metas.first(where: { $0.attr("name") == "cover" })?.attr("content") else { return nil }
        return items.first { $0.attr("id") == legacy }
    }

    func chapterPaths(packagePath: String) -> [String] {
        if metas.contains(where: { $0.attr("property") == "rendition:layout" && $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated" }) { return [] }
        let references = spine.elements("itemref", opf)
        var byID: [String: XMLElement] = [:]
        for item in items { if let id = item.attr("id") { byID[id] = item } }
        var paths: [String] = []
        var seen = Set<String>()
        for reference in references {
            guard reference.attr("properties")?.split(whereSeparator: \.isWhitespace).contains("rendition:layout-pre-paginated") != true,
                  let id = reference.attr("idref"), let item = byID[id] else { return [] }
            guard item.attr("media-type") == "application/xhtml+xml" else { continue }
            guard let href = item.attr("href"), let path = try? resourcePath(href, relativeTo: packagePath) else { return [] }
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    func touch() {
        guard version.hasPrefix("3") else { return }
        let modified = metas.first { $0.attr("property") == "dcterms:modified" && $0.attr("refines") == nil } ?? metadata.append("meta", namespace: opf)
        modified.setAttr("property", "dcterms:modified")
        modified.stringValue = ISO8601DateFormatter().string(from: Date())
    }
}

private let styleMarker = "/* NativeEpub typography: "

private func chapterHead(_ document: XMLDocument) throws -> XMLElement {
    guard let root = document.rootElement(), root.localName == "html", root.uri == xhtml,
          let head = root.elements("head", xhtml).first else {
        throw BookIssue("A reading-order chapter has no XHTML head. Its formatting could not be changed.")
    }
    return head
}

private func editorialStyle(in head: XMLElement) -> XMLElement? {
    head.elements("style", xhtml).first { $0.stringValue?.hasPrefix(styleMarker) == true }
}

private func typography(_ metadata: BookMetadata) -> String {
    var rules: [String] = []
    switch metadata.font {
    case .original: break
    case .serif: rules.append("font-family: serif !important;")
    case .sansSerif: rules.append("font-family: sans-serif !important;")
    }
    switch metadata.lineSpacing {
    case .original: break
    case .comfortable: rules.append("line-height: 1.5 !important;")
    case .spacious: rules.append("line-height: 1.8 !important;")
    }
    return styleMarker + metadata.font.rawValue + " " + metadata.lineSpacing.rawValue + " */\nbody, p, li, blockquote { " + rules.joined(separator: " ") + " }"
}

// Foundation rewrites external XHTML entities when it serializes a tree. Insert only
// our marked style block so chapter text, entities, DOCTYPE and publisher CSS survive.
private func formattingChapter(_ data: Data, metadata: BookMetadata) throws -> Data {
    let head = try chapterHead(parsedXML(data))
    let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) ? .utf16LittleEndian :
        data.starts(with: [0xFE, 0xFF]) ? .utf16BigEndian : .utf8
    guard var source = String(data: data, encoding: encoding), let headName = head.name else {
        throw BookIssue("This chapter uses an unsupported text encoding.")
    }
    let open = "<!--NativeEpub typography-->"
    let close = "<!--/NativeEpub typography-->"
    let usePublisher = metadata.font == .original && metadata.lineSpacing == .original
    let prefix = head.prefix.flatMap { $0.isEmpty ? nil : $0 + ":" } ?? ""
    func block(_ css: String) -> String {
        open + "<" + prefix + "style type=\"text/css\">" + css + "</" + prefix + "style>" + close
    }
    let next = usePublisher ? "" : block(typography(metadata))
    let mismatch = BookIssue("A chapter’s formatting markup could not be updated safely.")
    if let previous = editorialStyle(in: head)?.stringValue {
        guard let range = source.range(of: block(previous)) else { throw mismatch }
        source.replaceSubrange(range, with: next)
    } else if !usePublisher {
        let tag = "</" + NSRegularExpression.escapedPattern(for: headName) + #"\s*>"#
        guard let end = source.range(of: tag, options: .regularExpression),
              source.range(of: tag, options: .regularExpression, range: end.upperBound..<source.endIndex) == nil else { throw mismatch }
        source.insert(contentsOf: next, at: end.lowerBound)
    } else {
        return data
    }
    if data.starts(with: [0xEF, 0xBB, 0xBF]), !source.hasPrefix("\u{FEFF}") { source = "\u{FEFF}" + source }
    guard let updated = source.data(using: encoding) else { throw mismatch }
    let savedStyle = editorialStyle(in: try chapterHead(parsedXML(updated)))?.stringValue
    guard savedStyle == (usePublisher ? nil : typography(metadata)) else { throw mismatch }
    return updated
}

public struct EPUBBook: Sendable {
    public let metadata: BookMetadata
    public let coverData: Data?
    public let version: String
    public var allowsFormatting: Bool { !chapters.isEmpty }

    let archive: EPUBArchive
    let original: Data
    let packagePath: String
    let chapters: [String]

    public init(data: Data) throws {
        let archive = try EPUBArchive(data: data)
        guard !archive.names.contains("META-INF/encryption.xml"), !archive.names.contains("META-INF/signatures.xml") else {
            throw BookIssue("Encrypted and digitally signed EPUBs cannot be edited.")
        }
        let container = try parsedXML(archive.data(for: "META-INF/container.xml"))
        let ocf = "urn:oasis:names:tc:opendocument:xmlns:container"
        let rootfiles = container.rootElement()?.elements("rootfiles", ocf).first?.elements("rootfile", ocf) ?? []
        guard rootfiles.count == 1, let href = rootfiles.first?.attr("full-path") else {
            throw BookIssue("The EPUB needs a single package document.")
        }
        let path = archive.names.contains(href) ? href : try resourcePath(href, relativeTo: "")
        let package = try Package(data: archive.data(for: path))
        var metadata = BookMetadata()
        for (name, key) in fields {
            metadata[keyPath: key] = package.metadata.elements(name, dc).first?.stringValue ?? ""
        }
        var cover: Data?
        if let item = package.coverItem, let href = item.attr("href"), let path = try? resourcePath(href, relativeTo: path), archive.names.contains(path) {
            cover = try archive.data(for: path)
        }
        let chapters = package.chapterPaths(packagePath: path)
        if let first = chapters.first, let data = try? archive.data(for: first),
           let head = try? chapterHead(parsedXML(data)), let style = editorialStyle(in: head)?.stringValue,
           let markerEnd = style.range(of: " */") {
            let settings = style[style.index(style.startIndex, offsetBy: styleMarker.count)..<markerEnd.lowerBound].split(separator: " ")
            if settings.count == 2 {
                metadata.font = BookFont(rawValue: String(settings[0])) ?? .original
                metadata.lineSpacing = BookLineSpacing(rawValue: String(settings[1])) ?? .original
            }
        }
        self.metadata = metadata
        self.coverData = cover
        self.version = package.version
        self.archive = archive
        self.original = data
        self.packagePath = path
        self.chapters = chapters
    }

    public func writing(metadata edited: BookMetadata, replacementCover: Data?) throws -> Data {
        guard edited != metadata || replacementCover != nil else { return original }
        let package = try Package(data: archive.data(for: packagePath))
        for (name, key) in fields where edited[keyPath: key] != metadata[keyPath: key] {
            let value = edited[keyPath: key].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty || !["title", "language"].contains(name) else {
                throw BookIssue("A book needs both a title and a language.")
            }
            guard value.unicodeScalars.allSatisfy({ scalar in
                let n = scalar.value
                return n == 9 || n == 10 || n == 13 || (n >= 32 && n != 0xFFFE && n != 0xFFFF)
            }) else { throw BookIssue("A metadata field contains a character that EPUB does not allow.") }
            let existing = package.metadata.elements(name, dc).first
            if value.isEmpty {
                if let id = existing?.attr("id") {
                    for refinement in package.metas where refinement.attr("refines") == "#" + id { refinement.detach() }
                }
                existing?.detach()
            } else {
                let field = existing ?? package.metadata.append(name, namespace: dc)
                field.stringValue = value
            }
        }
        var updates: [String: Data] = [:]
        if edited.font != metadata.font || edited.lineSpacing != metadata.lineSpacing {
            guard allowsFormatting else { throw BookIssue("Reading format can only be changed in a reflowable XHTML book.") }
            for path in chapters {
                updates[path] = try formattingChapter(archive.data(for: path), metadata: edited)
            }
        }
        if let replacementCover {
            let (path, bytes) = try coverUpdate(replacementCover, package: package)
            updates[path] = bytes
        }
        package.touch()
        updates[packagePath] = package.document.xmlData(options: .nodeCompactEmptyElement)
        return try archive.replacing(updates)
    }

    private func coverUpdate(_ bytes: Data, package: Package) throws -> (String, Data) {
        guard bytes.count <= 40 * 1024 * 1024, let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(image) as String?, let imageType = UTType(type),
              [.jpeg, .png].contains(imageType), let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height, CGImageSourceGetStatus(image) == .statusComplete else {
            throw BookIssue("Choose a complete JPEG or PNG cover under 40 MB and 64 megapixels.")
        }
        if let item = package.coverItem, let href = item.attr("href") {
            let path = try resourcePath(href, relativeTo: packagePath)
            guard path != packagePath, path != "mimetype", !path.hasPrefix("META-INF/"), !chapters.contains(path) else {
                throw BookIssue("The cover points to a reserved book resource.")
            }
            let targets: [String: UTType] = ["image/jpeg": .jpeg, "image/png": .png, "image/gif": .gif]
            guard let mime = item.attr("media-type"), let target = targets[mime] else {
                throw BookIssue("The existing cover uses a format this editor cannot replace safely.")
            }
            if imageType == target { return (path, bytes) }
            let encoded = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(encoded, target.identifier as CFString, 1, nil) else {
                throw BookIssue("The replacement cover could not be encoded.")
            }
            CGImageDestinationAddImageFromSource(output, image, 0, nil)
            guard CGImageDestinationFinalize(output) else { throw BookIssue("The replacement cover could not be encoded.") }
            return (path, encoded as Data)
        }
        let ext = imageType == .jpeg ? "jpg" : "png"
        var suffix = ""
        var count = 1
        let ids = Set(try package.document.nodes(forXPath: "//@id").compactMap(\.stringValue))
        let names = Set(archive.names)
        while true {
            let id = "nativeepub-cover" + suffix
            let filename = id + "." + ext
            let path = try resourcePath(filename, relativeTo: packagePath)
            if !ids.contains(id), !names.contains(path) {
                let item = package.manifest.append("item", namespace: opf)
                item.setAttr("id", id)
                item.setAttr("href", filename)
                item.setAttr("media-type", imageType == .jpeg ? "image/jpeg" : "image/png")
                if package.version.hasPrefix("3") { item.setAttr("properties", "cover-image") }
                if package.version.hasPrefix("2") || package.metas.contains(where: { $0.attr("name") == "cover" }) {
                    let meta = package.metas.first { $0.attr("name") == "cover" } ?? package.metadata.append("meta", namespace: opf)
                    meta.setAttr("name", "cover")
                    meta.setAttr("content", id)
                }
                return (path, bytes)
            }
            count += 1
            suffix = "-\(count)"
        }
    }
}
