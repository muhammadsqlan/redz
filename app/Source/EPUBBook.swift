import Foundation

struct ReaderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Chapter {
    let url: URL
    let title: String
}

struct ContentsEntry {
    let title: String
    let chapter: Int
    let anchor: String
    let depth: Int
}

struct EPUBBook {
    let source: URL
    let root: URL
    let title: String
    let chapters: [Chapter]
    let contents: [ContentsEntry]
    let initialChapter: Int

    static func open(_ source: URL, library: URL) throws -> EPUBBook {
        guard source.pathExtension.lowercased() == "epub" else { throw ReaderError(message: "Choose an EPUB.") }
        try validateArchive(source)
        let root = library.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-n", source.path, "-d", root.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReaderError(message: "Couldn’t open this EPUB. " + (String(data: errorData, encoding: .utf8) ?? ""))
        }
        let container = try xml(root.appendingPathComponent("META-INF/container.xml"))
        guard let packagePath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw ReaderError(message: "Missing EPUB package.")
        }
        let packageURL = try safeURL(packagePath, relativeTo: root, root: root)
        let package = try xml(packageURL)
        let base = packageURL.deletingLastPathComponent()
        let title = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue ?? source.deletingPathExtension().lastPathComponent
        var manifest: [String: URL] = [:]
        var navigation: URL?
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue else { continue }
            let url = try safeURL(href, relativeTo: base, root: root)
            manifest[id] = url
            if item.attribute(forName: "properties")?.stringValue?.split(separator: " ").contains("nav") == true { navigation = url }
        }
        var chapters: [Chapter] = []
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            guard item.attribute(forName: "linear")?.stringValue != "no", let id = item.attribute(forName: "idref")?.stringValue, let url = manifest[id] else { continue }
            guard ["xhtml", "html", "htm"].contains(url.pathExtension.lowercased()) else { continue }
            let doc = try xml(url)
            let name = try doc.nodes(forXPath: "//*[local-name()='head']/*[local-name()='title']").first?.stringValue ?? "Chapter \(chapters.count + 1)"
            chapters.append(Chapter(url: url, title: name))
        }
        guard !chapters.isEmpty else { throw ReaderError(message: "No readable chapters.") }
        var contents: [ContentsEntry] = []
        if let navigation = navigation, let nav = try? xml(navigation) {
            let links = (try? nav.nodes(forXPath: "//*[local-name()='nav' and (@id='toc' or @*[local-name()='type']='toc')]//*[local-name()='a']")) ?? []
            for case let link as XMLElement in links {
                guard let href = link.attribute(forName: "href")?.stringValue else { continue }
                let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                guard let url = try? safeURL(String(parts[0]), relativeTo: navigation.deletingLastPathComponent(), root: root), let index = chapters.firstIndex(where: { $0.url == url }) else { continue }
                var depth = -1
                var parent = link.parent
                while let node = parent { if node.localName == "ol" { depth += 1 }; parent = node.parent }
                contents.append(ContentsEntry(title: (link.stringValue ?? chapters[index].title).replacingOccurrences(of: "\u{00a0}", with: " "), chapter: index, anchor: parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : "", depth: max(0, depth)))
            }
        }
        if contents.isEmpty { contents = chapters.enumerated().map { ContentsEntry(title: $0.element.title, chapter: $0.offset, anchor: "", depth: 0) } }
        let startHref = try package.nodes(forXPath: "//*[local-name()='guide']/*[local-name()='reference' and @type='text']/@href").first?.stringValue
        let startURL = startHref.flatMap { try? safeURL($0, relativeTo: base, root: root) }
        let first = startURL.flatMap { url in chapters.firstIndex(where: { $0.url == url }) } ?? 0
        return EPUBBook(source: source, root: root, title: title, chapters: chapters, contents: contents, initialChapter: first)
    }

    private static func xml(_ url: URL) throws -> XMLDocument {
        try XMLDocument(contentsOf: url, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    }

    static func safeURL(_ path: String, relativeTo base: URL, root: URL) throws -> URL {
        let clean = path.components(separatedBy: "#")[0].removingPercentEncoding ?? path
        guard !clean.hasPrefix("/"), !clean.contains(":"), !clean.contains("\\"), !clean.contains("\0") else { throw ReaderError(message: "Unsafe EPUB path.") }
        let url = base.appendingPathComponent(clean).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ReaderError(message: "Unsafe EPUB path.") }
        return url
    }

    // Inspect the ZIP directory before extraction; reject traversal, symlinks,
    // encryption, ZIP64, duplicate files, and unreasonable expansion sizes.
    static func validateArchive(_ source: URL) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        func u16(_ p: Int) throws -> Int { guard p >= 0 && p + 2 <= data.count else { throw ReaderError(message: "Invalid EPUB archive.") }; return Int(data[p]) | Int(data[p+1]) << 8 }
        func u32(_ p: Int) throws -> UInt32 { guard p >= 0 && p + 4 <= data.count else { throw ReaderError(message: "Invalid EPUB archive.") }; return UInt32(data[p]) | UInt32(data[p+1]) << 8 | UInt32(data[p+2]) << 16 | UInt32(data[p+3]) << 24 }
        guard data.count >= 22 && data.count <= 150_000_000 else { throw ReaderError(message: "EPUB is too large or invalid.") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(i) == 0x06054b50, i + 22 + (try u16(i+20)) == data.count { end = i; break }
        }
        guard let end = end, try u16(end+4) == 0, try u16(end+6) == 0 else { throw ReaderError(message: "Unsupported EPUB archive.") }
        let count = try u16(end+10)
        guard count > 0 && count < 10_000 else { throw ReaderError(message: "Unsupported EPUB archive.") }
        var p = Int(try u32(end+16))
        var total: UInt64 = 0
        var names: Set<String> = []
        for _ in 0..<count {
            guard try u32(p) == 0x02014b50 else { throw ReaderError(message: "Invalid EPUB directory.") }
            let flags = try u16(p+8), method = try u16(p+10), size = try u32(p+24)
            let nameLength = try u16(p+28), extra = try u16(p+30), comment = try u16(p+32)
            let attributes = try u32(p+38)
            guard p + 46 + nameLength + extra + comment <= data.count, let name = String(data: data[(p+46)..<(p+46+nameLength)], encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.contains("\n"), !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."), names.insert(name).inserted else { throw ReaderError(message: "Unsafe EPUB archive.") }
            guard flags & 1 == 0, [0, 8].contains(method), (attributes >> 16) & 0o170000 != 0o120000, size < 100_000_000 else { throw ReaderError(message: "Unsupported EPUB archive.") }
            total += UInt64(size)
            guard total < 500_000_000 else { throw ReaderError(message: "EPUB expands beyond the limit.") }
            p += 46 + nameLength + extra + comment
        }
    }
}
