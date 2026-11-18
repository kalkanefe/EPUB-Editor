import Foundation

public struct KindleRepairResult: Sendable {
    public let data: Data
    public let stylesFixed: Int
    public let stylesheetLinksCreated: Int
    public let skippedResources: Int
    public let containerFixed: Bool
    public var changed: Bool { stylesFixed > 0 || stylesheetLinksCreated > 0 || containerFixed }
}

private let xhtmlNamespace = "http://www.w3.org/1999/xhtml"
private let packageNamespace = "http://www.idpf.org/2007/opf"

// Restrict edits to flat, explicit declarations in ordinary prose. The scanner skips
// strings, comments, functions, escaped characters, and nested rules such as @media.
private func repairedCSS(_ css: String, proseClass: String? = nil) -> (text: String, count: Int) {
    let bytes = Array(css.utf8)
    var changes: [(Range<Int>, String)] = []
    var depth = 0, parentheses = 0, start = 0, i = 0
    var proseRule = false, pageRule = false
    func fixDeclaration(endingAt end: Int) {
        guard proseRule, start < end, let colon = bytes[start..<end].firstIndex(of: 58) else { return }
        let property = String(decoding: bytes[start..<colon], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacement: String
        switch property {
        case "font-size": replacement = "1em"
        case "line-height": replacement = "normal"
        case "width" where pageRule, "height" where pageRule: replacement = "auto"
        default: return
        }
        // An unqualified positive absolute length is unambiguous. Keep all other CSS,
        // including calc(), variables, relative lengths, and importance, as authored.
        let value = String(decoding: bytes[colon + 1..<end], as: UTF8.self)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = absoluteLength.firstMatch(in: value, range: range),
              let valueRange = Range(match.range(at: 1), in: value),
              let numberRange = Range(match.range(at: 2), in: value),
              let number = Double(value[numberRange]), number > 0, number.isFinite else { return }
        let begin = colon + 1 + value[..<valueRange.lowerBound].utf8.count
        changes.append((begin..<begin + value[valueRange].utf8.count, replacement))
    }
    while i < bytes.count {
        let c = bytes[i]
        if c == 34 || c == 39 {
            i += 1
            while i < bytes.count, bytes[i] != c {
                if bytes[i] == 92 { i += 1 }
                i += 1
            }
            guard i < bytes.count else { return (css, 0) }
        } else if c == 47, i + 1 < bytes.count, bytes[i + 1] == 42 {
            i += 2
            while i + 1 < bytes.count, !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
            guard i + 1 < bytes.count else { return (css, 0) }
            i += 1
        } else if c == 92 {
            i += 1
        } else if c == 40 {
            parentheses += 1
        } else if c == 41 {
            guard parentheses > 0 else { return (css, 0) }
            parentheses -= 1
        } else if parentheses == 0 {
            switch c {
            case 123: // {
                if depth == 0 {
                    let selector = String(decoding: bytes[start..<i], as: UTF8.self)
                    let selectors = selector.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    pageRule = selectors.allSatisfy { ["html", "body"].contains($0) }
                    proseRule = selectors.allSatisfy {
                        ["html", "body", "p", "li"].contains($0) ||
                            (proseClass.map { name in ["." + name, "span." + name] } ?? []).contains($0)
                    }
                    start = i + 1
                } else { proseRule = false }
                depth += 1
            case 125: // }
                guard depth > 0 else { return (css, 0) }
                if depth == 1 { fixDeclaration(endingAt: i) }
                depth -= 1
                start = i + 1
            case 59: // ;
                if depth == 1 { fixDeclaration(endingAt: i) }
                start = i + 1
            default: break
            }
        }
        i += 1
    }
    guard depth == 0, parentheses == 0, !changes.isEmpty else { return (css, 0) }
    var output: [UInt8] = []
    var copied = 0
    for (range, replacement) in changes {
        output.append(contentsOf: bytes[copied..<range.lowerBound])
        output.append(contentsOf: replacement.utf8)
        copied = range.upperBound
    }
    output.append(contentsOf: bytes[copied...])
    return (String(decoding: output, as: UTF8.self), changes.count)
}

private let absoluteLength = try! NSRegularExpression(pattern: #"^\s*((\d*\.?\d+)(?:px|pt|pc|mm|cm|in))\s*(?:!\s*important\s*)?$"#, options: .caseInsensitive)
private let styleTag = try! NSRegularExpression(pattern: #"<style(?:\s+type\s*=\s*(?:"text/css"|'text/css'))?\s*>([\s\S]*?)</style\s*>"#)
private let simpleClass = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_-]*$"#)

private struct ChapterStyle {
    let path: String
    let markup: String
    let tag: Range<String.Index>
    let css: String
    let proseClass: String?
    let paragraphs: Int
    let headChildIndex: Int

    // Only a uniform, whole-paragraph export wrapper qualifies as a prose class.
    // If its class also styles even one heading or other element, preserve it.
    private static func bodyTextClass(_ document: XMLDocument) throws -> (String?, Int) {
        let nodes = try document.nodes(forXPath: "//*[local-name()='p']").compactMap { $0 as? XMLElement }
        var candidate: String?
        for p in nodes {
            guard p.uri == xhtmlNamespace else { return (nil, 0) }
            var parent = p.parent as? XMLElement
            while let node = parent, node.localName != "body" {
                guard ["section", "article", "div", "main"].contains(node.localName ?? "") else { return (nil, 0) }
                parent = node.parent as? XMLElement
            }
            guard parent?.localName == "body" else { return (nil, 0) }
            let children = (p.children ?? []).filter { $0.kind != .text || $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            guard children.count == 1, let span = children[0] as? XMLElement, span.localName == "span", span.uri == xhtmlNamespace,
                  let name = span.attr("class"), name.utf8.count <= 128,
                  simpleClass.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
                  candidate == nil || name == candidate else { return (nil, 0) }
            candidate = name
        }
        guard let candidate else { return (nil, 0) }
        let owners = try document.nodes(forXPath: "//*[@class]").compactMap { $0 as? XMLElement }.filter {
            $0.attr("class")?.split(whereSeparator: \.isWhitespace).contains(Substring(candidate)) == true
        }
        return owners.count == nodes.count ? (candidate, nodes.count) : (nil, 0)
    }

    static func read(_ data: Data, path: String) throws -> ChapterStyle? {
        guard let markup = String(validating: data, as: UTF8.self) else { throw BookIssue("Unsupported chapter encoding.") }
        let document = try parsedXML(data)
        guard let root = document.rootElement(), root.uri == xhtmlNamespace, root.localName == "html",
              let head = root.elements("head", xhtmlNamespace).first else { throw BookIssue("Unsupported chapter markup.") }
        let hasCSP = head.elements("meta", xhtmlNamespace).contains {
            $0.attr("http-equiv")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-security-policy"
        }
        let styles = head.elements("style", xhtmlNamespace).filter { $0.stringValue?.hasPrefix("/* NativeEpub typography: ") != true }
        guard !styles.isEmpty else { return nil }
        guard !hasCSP, styles.count == 1, styles[0].name == "style",
              (styles[0].attributes ?? []).allSatisfy({ $0.name == "type" && $0.stringValue == "text/css" }),
              let css = styles[0].stringValue, css.utf8.count <= 512 * 1024,
              try document.nodes(forXPath: "//*[@xml:base] | //*[local-name()='base' or local-name()='script'] | //@*[starts-with(local-name(),'on')]").isEmpty,
              let index = head.children?.firstIndex(where: { $0 === styles[0] }) else { throw BookIssue("Unsupported chapter styles.") }
        // Match bytes and the parsed element. Never serialize a chapter: EPUB 2
        // DOCTYPEs and named entities must survive round trips through Foundation.
        let full = NSRange(markup.startIndex..., in: markup)
        let matches = styleTag.matches(in: markup, range: full).filter {
            guard let inner = Range($0.range(at: 1), in: markup) else { return false }
            return markup[inner] == css || markup[inner] == "<![CDATA[" + css + "]]>"
        }
        guard matches.count == 1, let tag = Range(matches[0].range, in: markup) else { throw BookIssue("Ambiguous inline style markup.") }
        let (proseClass, paragraphs) = try bodyTextClass(document)
        return ChapterStyle(path: path, markup: markup, tag: tag, css: css, proseClass: proseClass, paragraphs: paragraphs, headChildIndex: index)
    }

    func replacingStyle(with element: String, expectedName: String, value: String) throws -> Data {
        let next = markup.replacingCharacters(in: tag, with: element)
        let data = Data(next.utf8)
        let doc = try parsedXML(data)
        let head = doc.rootElement()?.elements("head", xhtmlNamespace).first
        guard let children = head?.children, children.indices.contains(headChildIndex),
              let child = children[headChildIndex] as? XMLElement, child.localName == expectedName, child.uri == xhtmlNamespace,
              (expectedName == "link" ? child.attr("href") : child.stringValue) == value else {
            throw BookIssue("The chapter’s stylesheet could not be repaired safely.")
        }
        return data
    }
}

// The shared sheet lives alongside the OPF. Its generated name uses only ASCII.
// Each path segment going up from a chapter and down to the OPF is encoded separately.
private func relativeReference(to destination: String, from source: String) -> String {
    var parent = ArraySlice(source.split(separator: "/").dropLast())
    var target = ArraySlice(destination.split(separator: "/"))
    while let part = parent.first, target.first == part { parent = parent.dropFirst(); target = target.dropFirst() }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return (Array(repeating: "..", count: parent.count) + target.map { String($0).addingPercentEncoding(withAllowedCharacters: allowed)! }).joined(separator: "/")
}

extension EPUBBook {
    public func repairingForKindle() throws -> KindleRepairResult {
        let package = try Package(data: archive.data(for: packagePath))
        let legacyFixed = package.metas.contains {
            $0.attr("name")?.lowercased() == "fixed-layout" && ["true", "yes", "1"].contains($0.attr("content")?.lowercased() ?? "")
        }
        let interactive = package.items.contains { item in
            item.attr("properties")?.split(whereSeparator: \.isWhitespace).contains("scripted") == true ||
                ["text/javascript", "application/javascript", "application/ecmascript", "text/ecmascript"].contains(item.attr("media-type"))
        }
        guard allowsFormatting, !legacyFixed, !interactive else {
            throw BookIssue("Kindle formatting repair is available for reflowable, non-interactive EPUBs.")
        }
        let displayOptions = "META-INF/com.apple.ibooks.display-options.xml"
        if archive.names.contains(displayOptions) {
            let options = try parsedXML(archive.data(for: displayOptions))
            if try options.nodes(forXPath: "//*[@name='fixed-layout']").contains(where: {
                ["yes", "true", "1"].contains($0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
            }) { throw BookIssue("This book declares a fixed page layout.") }
        }

        var skipped = 0, inspected = 0, fixes = 0, links = 0
        var updates: [String: Data] = [:]
        var groups: [Data: [ChapterStyle]] = [:]
        func candidate(_ path: String, limit: Int) throws -> Data? {
            guard let size = archive.expandedSize(of: path), size <= limit,
                  inspected + size <= 96 * 1024 * 1024 else { skipped += 1; return nil }
            inspected += size
            return try archive.data(for: path)
        }

        var seenCSS = Set<String>()
        for item in package.items where item.attr("media-type") == "text/css" {
            try Task.checkCancellation()
            guard let href = item.attr("href"), let path = try? resourcePath(href, relativeTo: packagePath),
                  path != packagePath, !path.hasPrefix("META-INF/"), path != "mimetype" else { skipped += 1; continue }
            guard seenCSS.insert(path).inserted, let bytes = try candidate(path, limit: 512 * 1024) else { continue }
            guard let css = String(validating: bytes, as: UTF8.self), !css.contains("\0") else { skipped += 1; continue }
            let result = repairedCSS(css)
            if result.count > 0 {
                updates[path] = Data(result.text.utf8)
                fixes += result.count
            }
        }
        for path in chapters {
            try Task.checkCancellation()
            guard let bytes = try candidate(path, limit: 8 * 1024 * 1024) else { continue }
            do {
                if let style = try autoreleasepool(invoking: { try ChapterStyle.read(bytes, path: path) }) {
                    groups[Data(style.css.utf8), default: []].append(style)
                }
            } catch { skipped += 1 }
        }

        var ids = Set(try package.document.nodes(forXPath: "//@id").compactMap(\.stringValue))
        var occupied = Set(archive.names)
        var serial = 1
        // Also reserve missing, but declared, resources; never steal another item's href.
        for item in package.items {
            if let href = item.attr("href"), let path = try? resourcePath(href, relativeTo: packagePath) { occupied.insert(path) }
        }
        // Iterate by first chapter for deterministic stylesheet names.
        let batches = groups.values.sorted { $0[0].path < $1[0].path }
        for batch in batches {
            try Task.checkCancellation()
            let first = batch[0]
            let uniform = batch.allSatisfy { $0.proseClass == first.proseClass } && batch.reduce(0, { $0 + $1.paragraphs }) >= 3
            let result = repairedCSS(first.css, proseClass: uniform ? first.proseClass : nil)
            // URL-bearing functions (including image-set), @imports and escapes may
            // depend on the original document's base or fragment. Leave them inline.
            let canShare = batch.count > 1 && !first.css.contains("(") && !first.css.contains("@") && !first.css.contains("\\")
            if canShare {
                var id: String, path: String
                repeat {
                    id = "epub-edit-kindle-\(serial)"
                    serial += 1
                    path = try resourcePath(id + ".css", relativeTo: packagePath)
                } while ids.contains(id) || occupied.contains(path)
                ids.insert(id)
                occupied.insert(path)
                for entry in batch {
                    let href = relativeReference(to: path, from: entry.path)
                    let link = "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(href)\"/>"
                    updates[entry.path] = try entry.replacingStyle(with: link, expectedName: "link", value: href)
                }
                links += batch.count
                updates[path] = Data(result.text.utf8)
                let item = package.manifest.append("item", namespace: packageNamespace)
                item.setAttr("id", id)
                item.setAttr("href", id + ".css")
                item.setAttr("media-type", "text/css")
            } else if result.count > 0 {
                let escaped = result.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                for entry in batch {
                    updates[entry.path] = try entry.replacingStyle(with: "<style type=\"text/css\">\(escaped)</style>", expectedName: "style", value: result.text)
                }
            }
            fixes += result.count * batch.count
        }
        if !updates.isEmpty {
            package.touch()
            if links > 0 || package.version.hasPrefix("3") {
                updates[packagePath] = package.document.xmlData(options: .nodeCompactEmptyElement)
            }
        }
        try Task.checkCancellation()
        let containerFixed = archive.needsMimetypeRepair
        let result = updates.isEmpty && !containerFixed ? original : try archive.replacing(updates)
        return KindleRepairResult(data: result, stylesFixed: fixes, stylesheetLinksCreated: links, skippedResources: skipped, containerFixed: containerFixed)
    }
}
