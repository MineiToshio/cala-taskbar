import Darwin
import Foundation
import UniformTypeIdentifiers

/// One attachment of a message, as listed in the reader. Nothing of it is downloaded until the person asks.
struct MailAttachment: Codable, Equatable, Hashable, Identifiable {
    /// IMAP part number, fetched with BODY.PEEK[section].
    let section: String
    /// Display name, already decoded (RFC 2047 / RFC 2231); not yet safe as a file name (see MailAttachmentFiles).
    let filename: String
    /// Lowercased "type/subtype".
    let mime: String
    /// Encoded size on the server, in bytes.
    let size: Int
    /// Content-Transfer-Encoding, lowercased ("base64", "quoted-printable"; nil for 7bit/8bit/binary).
    let encoding: String?

    var id: String { section }

    /// Decoded size estimate for display (base64 carries 3 bytes in 4).
    var approximateBytes: Int { encoding == "base64" ? size * 3 / 4 : size }

    /// The part's bytes as the server sent them, with the transfer encoding undone.
    static func decode(_ data: Data, encoding: String?) -> Data? {
        switch encoding?.lowercased() {
        case "base64", "quoted-printable": return MailMIME.decodeTransfer(data, encoding: encoding)
        default: return data
        }
    }

    /// A broad category for the row's symbol.
    var symbol: String {
        let type = mime.split(separator: "/").first.map(String.init) ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()
        if mime == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        switch type {
        case "image": return "photo"
        case "video": return "film"
        case "audio": return "waveform"
        case "message": return "envelope"
        case "text": return "doc.text"
        default: break
        }
        if ["zip", "gz", "tgz", "rar", "7z", "tar"].contains(ext) || mime.contains("zip") { return "doc.zipper" }
        if ["xls", "xlsx", "numbers", "csv"].contains(ext) { return "tablecells" }
        if ["ppt", "pptx", "key"].contains(ext) { return "rectangle.on.rectangle" }
        return "doc"
    }

    /// Largest attachment Cala downloads (decoded).
    static let downloadLimit = 50 * 1024 * 1024
    var isTooLarge: Bool { approximateBytes > Self.downloadLimit }
}

/// Which parts of a message are attachments (pure). From BODYSTRUCTURE when the server gave one, else from the whole
/// message (the full-download fallback). Body text and the inline cid pictures of a multipart/related are not listed.
enum MailAttachmentList {
    static func from(structure root: MailBodyPart) -> [MailAttachment] {
        var result: [MailAttachment] = []
        func walk(_ part: MailBodyPart, inRelated: Bool) {
            if part.isMultipart {
                for child in part.children { walk(child, inRelated: part.subtype == "related") }
                return
            }
            let name = filename(disposition: part.dispositionParameters, contentType: part.parameters)
            guard isAttachment(type: part.type, subtype: part.subtype, disposition: part.disposition, hasName: name != nil,
                               contentID: part.contentID, inRelated: inRelated, isMessage: part.isMessage) else { return }
            result.append(MailAttachment(section: part.section, filename: name ?? fallbackName(mime: part.mime, section: part.section),
                                         mime: part.mime, size: part.size, encoding: cleanEncoding(part.encoding)))
        }
        walk(root, inRelated: false)
        return result
    }

    /// The same list from a whole RFC 822 message, numbering parts as IMAP does.
    static func from(message raw: Data) -> [MailAttachment] {
        var result: [MailAttachment] = []
        func walk(_ entity: Data, section: String?, inRelated: Bool, depth: Int) {
            guard depth < 30 else { return }
            let (header, body) = split(entity)
            let fields = MailMIME.headers(header)
            let contentType = fields["content-type"] ?? "text/plain"
            let mime = value(contentType)
            let type = mime.split(separator: "/").first.map(String.init) ?? "text"
            let subtype = mime.split(separator: "/").dropFirst().first.map(String.init) ?? "plain"
            if type == "multipart" {
                guard let boundary = parameters(contentType)["boundary"], !boundary.isEmpty else { return }
                for (index, child) in parts(body, boundary: boundary).enumerated() {
                    let number = section.map { "\($0).\(index + 1)" } ?? "\(index + 1)"
                    walk(child, section: number, inRelated: subtype == "related", depth: depth + 1)
                }
                return
            }
            let dispositionField = fields["content-disposition"]
            let disposition = dispositionField.map(value)
            let name = filename(disposition: dispositionField.map(parameters) ?? [:], contentType: parameters(contentType))
            let isMessage = type == "message" && (subtype == "rfc822" || subtype == "global")
            guard isAttachment(type: type, subtype: subtype, disposition: disposition, hasName: name != nil,
                               contentID: fields["content-id"], inRelated: inRelated, isMessage: isMessage) else { return }
            let number = section ?? "1"
            result.append(MailAttachment(section: number, filename: name ?? fallbackName(mime: mime, section: number),
                                         mime: mime, size: body.count,
                                         encoding: cleanEncoding(fields["content-transfer-encoding"])))
        }
        walk(raw, section: nil, inRelated: false, depth: 0)
        return result
    }

    private static func isAttachment(type: String, subtype: String, disposition: String?, hasName: Bool, contentID: String?,
                                     inRelated: Bool, isMessage: Bool) -> Bool {
        if disposition == "attachment" || isMessage { return true }
        // Body text (what MailMIME shows).
        if type == "text" && (subtype == "plain" || subtype == "html") && !hasName { return false }
        // Pictures the HTML shows through cid: links.
        if inRelated && contentID != nil { return false }
        // Anything else that is not body text: a named inline part, or an unnamed binary part.
        return type != "text" || hasName
    }

    private static func cleanEncoding(_ encoding: String?) -> String? {
        guard let value = encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value == "base64" || value == "quoted-printable" else { return nil }
        return value
    }

    /// Content-Disposition filename (RFC 2231 `filename*`, continuations) or Content-Type name, decoded.
    static func filename(disposition: [String: String], contentType: [String: String]) -> String? {
        for (source, base) in [(disposition, "filename"), (contentType, "name")] {
            if let extended = rfc2231(source, name: base) { return extended }
            if let plain = source[base], !plain.isEmpty {
                let decoded = MailMIME.decodeHeader(plain).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    /// `name*=utf-8''caf%C3%A9.pdf`, or `name*0*=…; name*1*=…` / `name*0=…`.
    private static func rfc2231(_ source: [String: String], name: String) -> String? {
        var pieces: [(Int, String, Bool)] = []
        if let whole = source[name + "*"] { pieces.append((0, whole, true)) }
        for (key, value) in source where key.hasPrefix(name + "*") && key != name + "*" {
            var rest = key.dropFirst(name.count + 1)
            let encoded = rest.hasSuffix("*")
            if encoded { rest = rest.dropLast() }
            guard let index = Int(rest) else { continue }
            pieces.append((index, value, encoded))
        }
        guard !pieces.isEmpty else { return nil }
        pieces.sort { $0.0 < $1.0 }
        var charset = "utf-8"
        var bytes = Data()
        for (number, piece) in pieces.enumerated() {
            var value = Substring(piece.1)
            if piece.2 {
                if number == 0, let first = value.firstIndex(of: "'"),
                   let second = value[value.index(after: first)...].firstIndex(of: "'") {
                    let declared = value[..<first]
                    if !declared.isEmpty { charset = String(declared) }
                    value = value[value.index(after: second)...]
                }
                bytes.append(percentDecoded(value))
            } else {
                bytes.append(Data(value.utf8))
            }
        }
        let text = MailMIME.decodeCharset(bytes, charset: charset).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func percentDecoded(_ text: Substring) -> Data {
        var result = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "%", let a = text.index(index, offsetBy: 1, limitedBy: text.endIndex), a < text.endIndex,
               let b = text.index(index, offsetBy: 2, limitedBy: text.endIndex), b < text.endIndex,
               let byte = UInt8(String(text[a...b]), radix: 16) {
                result.append(byte)
                index = text.index(after: b)
            } else {
                result.append(contentsOf: Array(String(character).utf8))
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func fallbackName(mime: String, section: String) -> String {
        let base = tx("Attachment", "Adjunto") + " " + section
        if mime == "message/rfc822" || mime == "message/global" { return base + ".eml" }
        guard let ext = UTType(mimeType: mime)?.preferredFilenameExtension else { return base }
        return base + "." + ext
    }

    // MARK: Minimal MIME reading for the raw fallback

    private static func split(_ entity: Data) -> (header: Data, body: Data) {
        if entity.starts(with: [13, 10]) { return (Data(), Data(entity.dropFirst(2))) }
        if entity.starts(with: [10]) { return (Data(), Data(entity.dropFirst())) }
        let candidates = [Data([13, 10, 13, 10]), Data([10, 10])].compactMap { entity.range(of: $0) }
        guard let separator = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else { return (entity, Data()) }
        return (Data(entity[..<separator.lowerBound]), Data(entity[separator.upperBound...]))
    }

    private static func parts(_ body: Data, boundary: String) -> [Data] {
        let marker = Data(("--" + boundary).utf8)
        var result: [Data] = []
        var start: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: 10) ?? body.endIndex
            let line = body[lineStart..<lineEnd]
            let next = lineEnd < body.endIndex ? lineEnd + 1 : body.endIndex
            if line.starts(with: marker) {
                let rest = line.dropFirst(marker.count)
                let closing = rest.starts(with: [45, 45])
                let padding = closing ? rest.dropFirst(2) : rest
                if padding.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) {
                    if let start {
                        var end = lineStart
                        if end > start, body[end - 1] == 10 { end -= 1 }
                        if end > start, body[end - 1] == 13 { end -= 1 }
                        result.append(Data(body[start..<end]))
                    }
                    if closing { return result }
                    start = next
                }
            }
            lineStart = next
        }
        if let start, start < body.endIndex { result.append(Data(body[start...])) }
        return result
    }

    private static func value(_ field: String) -> String {
        field.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static let parameterPattern = try! NSRegularExpression(
        pattern: #";\s*([\w*-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;\s]+))"#
    )

    static func parameters(_ field: String) -> [String: String] {
        var result: [String: String] = [:]
        let text = field as NSString
        for match in parameterPattern.matches(in: field, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1)).lowercased()
            guard result[name] == nil else { continue }
            if match.range(at: 2).location != NSNotFound {
                result[name] = text.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            } else {
                result[name] = text.substring(with: match.range(at: 3))
            }
        }
        return result
    }
}

/// Saving an attachment the person asked for (pure helpers plus the write itself).
enum MailAttachmentFiles {
    /// A file name that is safe to create: no path separators or control characters, no leading dots, not empty,
    /// at most 200 characters (the extension is kept).
    static func sanitize(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format {
                return "_"
            }
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "_" { cleaned = tx("Attachment", "Adjunto") }
        if cleaned.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 16 ? 200 : 200 - ext.count - 1
            cleaned = String(cleaned.prefix(keep)) + (ext.isEmpty || ext.count > 16 ? "" : "." + ext)
        }
        return cleaned
    }

    /// `name` in `directory`, or "name 2.ext", "name 3.ext"… when taken.
    static func uniqueURL(for name: String, in directory: URL, exists: (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }) -> URL {
        let safe = sanitize(name)
        let first = directory.appendingPathComponent(safe)
        guard exists(first) else { return first }
        let ext = (safe as NSString).pathExtension
        let stem = ext.isEmpty ? safe : (safe as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// The quarantine record browsers write for downloads ("0083;<hex seconds>;<agent>;<id>"), so Gatekeeper checks
    /// the file before it can run.
    static func quarantineValue(date: Date = Date(), agent: String = "Cala", id: UUID = UUID()) -> String {
        String(format: "0083;%08x;%@;%@", UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970)), agent, id.uuidString)
    }

    /// Writes `data` under a unique, sanitized name in `directory` (never replacing a file) and quarantines it. The file
    /// is never opened or run.
    static func save(_ data: Data, named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<20 {
            let url = uniqueURL(for: name, in: directory)
            // O_EXCL: never replace a file, even one that appeared since uniqueURL looked.
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw CocoaError(.fileWriteNoPermission)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try quarantine(url)   // before any byte is in place
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return url
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func quarantine(_ url: URL) throws {
        let value = quarantineValue()
        let result = value.withCString { pointer in
            setxattr(url.path, "com.apple.quarantine", pointer, strlen(pointer), 0, 0)
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}

/// Where a clicked attachment's download is.
enum MailAttachmentState: Equatable {
    case idle
    /// 0...1 of the encoded size received so far.
    case downloading(Double)
    /// Bytes are in memory (MailService.attachmentData).
    case ready
    case failed
}
