import Foundation

/// One node of an IMAP BODYSTRUCTURE (RFC 3501 §7.4.2), with its part number ("1", "2.1"; "1" for a single-part message).
struct MailBodyPart: Equatable {
    var section: String
    var type: String            // lowercased, e.g. "text", "multipart"
    var subtype: String         // lowercased, e.g. "html", "alternative"
    var parameters: [String: String] = [:]   // names lowercased
    var contentID: String?
    var encoding: String?
    var size: Int = 0
    var disposition: String?    // lowercased disposition type ("attachment", "inline")
    var children: [MailBodyPart] = []
    /// message/rfc822 or message/global: the forwarded message's own structure.
    var message: [MailBodyPart] = []

    var isMultipart: Bool { type == "multipart" }
    var isMessage: Bool { type == "message" && (subtype == "rfc822" || subtype == "global") }
    var mime: String { type + "/" + subtype }
    var isAttachment: Bool { disposition == "attachment" }
    var leaves: [MailBodyPart] { isMultipart ? children.flatMap(\.leaves) : [self] }
    var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
}

enum MailBodyStructure {
    private indirect enum Node: Equatable {
        case value(String?)     // atom, quoted or literal; NIL is nil
        case list([Node])

        var string: String? { if case let .value(text) = self { return text }; return nil }
        var list: [Node]? { if case let .list(items) = self { return items }; return nil }
    }

    /// Parses the tokens of one BODYSTRUCTURE value, starting at its opening parenthesis. nil when it doesn't parse.
    static func parse(_ tokens: [MailIMAPToken]) -> MailBodyPart? {
        var index = 0
        guard let node = node(tokens, &index), index == tokens.count, case let .list(items) = node else { return nil }
        return part(items, section: nil, depth: 0)
    }

    private static func node(_ tokens: [MailIMAPToken], _ index: inout Int) -> Node? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        index += 1
        switch token {
        case .openList:
            var items: [Node] = []
            while index < tokens.count, tokens[index] != .closeList {
                guard let child = node(tokens, &index) else { return nil }
                items.append(child)
            }
            guard index < tokens.count else { return nil }
            index += 1
            return .list(items)
        case .closeList:
            return nil
        case let .atom(text):
            return .value(text.uppercased() == "NIL" ? nil : text)
        case let .quoted(text):
            return .value(text)
        case let .literal(bytes):
            return .value(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// `section` nil: the top level, whose single part is "1" and whose multipart children are "1", "2"...
    private static func part(_ items: [Node], section: String?, depth: Int) -> MailBodyPart? {
        guard depth < 30, !items.isEmpty else { return nil }
        func childSection(_ n: Int) -> String { section.map { "\($0).\(n)" } ?? "\(n)" }
        if items[0].list != nil {
            var children: [MailBodyPart] = []
            var index = 0
            while index < items.count, let list = items[index].list {
                guard let child = part(list, section: childSection(index + 1), depth: depth + 1) else { return nil }
                children.append(child)
                index += 1
            }
            guard index < items.count, let subtype = items[index].string else { return nil }
            var result = MailBodyPart(section: section ?? "", type: "multipart", subtype: subtype.lowercased())
            result.children = children
            if index + 1 < items.count { result.parameters = parameters(items[index + 1]) }
            if index + 2 < items.count { result.disposition = disposition(items[index + 2]) }
            return result
        }
        guard items.count >= 7, let type = items[0].string, let subtype = items[1].string,
              let size = items[6].string.flatMap(Int.init) else { return nil }
        var result = MailBodyPart(section: section ?? "1", type: type.lowercased(), subtype: subtype.lowercased())
        result.parameters = parameters(items[2])
        result.contentID = items[3].string
        result.encoding = items[5].string?.lowercased()
        result.size = size
        var extensionStart = 7
        if result.type == "text" {
            extensionStart = 8
        } else if result.isMessage {
            // envelope, body, lines
            guard items.count >= 10, let inner = items[8].list,
                  let forwarded = part(inner, section: result.section, depth: depth + 1) else { return nil }
            result.message = [forwarded]
            extensionStart = 10
        }
        // body-ext-1part: md5, then disposition
        if extensionStart + 1 < items.count { result.disposition = disposition(items[extensionStart + 1]) }
        return result
    }

    private static func parameters(_ node: Node) -> [String: String] {
        guard let list = node.list else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < list.count {
            if let name = list[index].string?.lowercased(), let value = list[index + 1].string, result[name] == nil {
                result[name] = value
            }
            index += 2
        }
        return result
    }

    private static func disposition(_ node: Node) -> String? {
        node.list?.first?.string?.lowercased()
    }
}

/// Which parts of a message the reader needs, so opening it never downloads attachments. The choice mirrors
/// MailMIME.content: text/plain and text/html parts that are not attachments, plus the images of a
/// multipart/related (the cid: pictures the sanitizer inlines). nil means "not sure": fetch the whole message.
struct MailPartPlan: Equatable {
    /// Leaf sections to fetch, each with its MIME header (BODY.PEEK[s.MIME] and BODY.PEEK[s]), in document order.
    let sections: [String]
    /// Encoded size of those parts, as BODYSTRUCTURE reports them.
    let bytes: Int

    /// Anything bigger than this is fetched whole (one FETCH response must fit the framer's limit).
    static let partialLimit = 20 * 1024 * 1024

    static func plan(_ root: MailBodyPart) -> MailPartPlan? {
        // A single part is the whole message anyway; forwarded messages and attachment containers are left to MailMIME.
        guard root.isMultipart, !root.isAttachment, root.depth < 25, isPlainTree(root) else { return nil }
        var sections: [String] = []
        var bytes = 0
        collect(root, into: &sections, bytes: &bytes)
        guard !sections.isEmpty, bytes <= partialLimit else { return nil }
        return MailPartPlan(sections: sections, bytes: bytes)
    }

    private static func isPlainTree(_ part: MailBodyPart) -> Bool {
        if part.isMessage || part.type == "message" { return false }
        guard part.isMultipart else { return !part.section.isEmpty }
        if part.isAttachment || part.parameters["boundary"]?.isEmpty != false || part.children.isEmpty { return false }
        return part.children.allSatisfy(isPlainTree)
    }

    private static func collect(_ part: MailBodyPart, into sections: inout [String], bytes: inout Int) {
        for (index, child) in part.children.enumerated() {
            if child.isMultipart {
                collect(child, into: &sections, bytes: &bytes)
                continue
            }
            let text = child.type == "text" && (child.subtype == "plain" || child.subtype == "html") && !child.isAttachment
            let relatedImage = part.subtype == "related" && child.type == "image" && child.contentID != nil
                && (index > 0 || part.parameters["start"] != nil)
            if text || relatedImage {
                sections.append(child.section)
                bytes += child.size
            }
        }
    }

    /// The part a list preview reads when the start of the message text had nothing readable (large CSS, say): the first
    /// text/plain part that is not an attachment, else the first such text/html part.
    static func previewPart(_ root: MailBodyPart) -> MailBodyPart? {
        let candidates = root.leaves.filter { $0.type == "text" && !$0.isAttachment && $0.parameters["name"] == nil }
        return candidates.first { $0.subtype == "plain" } ?? candidates.first { $0.subtype == "html" }
    }

    /// The header fields MailMIME.snippet needs to decode one part on its own.
    static func headerFields(for part: MailBodyPart) -> [String: String] {
        var contentType = part.mime
        if let charset = part.parameters["charset"] { contentType += "; charset=\"\(charset)\"" }
        var fields = ["content-type": contentType]
        if let encoding = part.encoding { fields["content-transfer-encoding"] = encoding }
        return fields
    }
}

/// Rebuilds a MIME message from the fetched parts so MailMIME.content can read it exactly as it reads the whole message:
/// the multipart skeleton comes from BODYSTRUCTURE with a fresh boundary, fetched parts keep their own MIME headers and
/// encoded bytes, and every other leaf becomes an empty attachment (which MailMIME skips, as it skips the original).
enum MailPartAssembler {
    struct Part: Equatable {
        let header: Data   // BODY[s.MIME], normally ending with an empty line
        let body: Data     // BODY[s]
    }

    static func assemble(_ root: MailBodyPart, parts: [String: Part], boundary seed: String) -> Data? {
        guard root.isMultipart else { return nil }
        let marker = Data(("--cala-" + seed).utf8)
        // A fetched part that contains the boundary would cut itself in two.
        guard !parts.values.contains(where: { $0.body.range(of: marker) != nil || $0.header.range(of: marker) != nil }) else {
            return nil
        }
        var counter = 0
        return multipart(root, parts: parts, seed: seed, counter: &counter)
    }

    private static func multipart(_ part: MailBodyPart, parts: [String: Part], seed: String, counter: inout Int) -> Data {
        counter += 1
        let boundary = "cala-\(seed)-\(counter)"
        var header = "Content-Type: multipart/\(part.subtype); boundary=\"\(boundary)\""
        if let start = part.parameters["start"] {
            header += "; start=\"" + start.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var data = Data((header + "\r\n\r\n").utf8)
        for child in part.children {
            data.append(Data("--\(boundary)\r\n".utf8))
            if child.isMultipart {
                data.append(multipart(child, parts: parts, seed: seed, counter: &counter))
            } else if let fetched = parts[child.section] {
                data.append(normalizedHeader(fetched.header))
                data.append(fetched.body)
            } else {
                data.append(Data("Content-Type: application/octet-stream\r\nContent-Disposition: attachment\r\n\r\n".utf8))
            }
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// The header must end with one empty line, or MailMIME would read the body as more header.
    private static func normalizedHeader(_ header: Data) -> Data {
        if header.isEmpty { return Data("\r\n".utf8) }
        if header.hasSuffix(Data("\r\n\r\n".utf8)) || header.hasSuffix(Data("\n\n".utf8)) { return header }
        if header.hasSuffix(Data("\r\n".utf8)) { return header + Data("\r\n".utf8) }
        if header.hasSuffix(Data("\n".utf8)) { return header + Data("\n".utf8) }
        return header + Data("\r\n\r\n".utf8)
    }
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool { count >= suffix.count && self[(endIndex - suffix.count)...] == suffix }
}
