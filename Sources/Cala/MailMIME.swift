import Foundation

enum MailProvider: String, Codable, CaseIterable {
    case gmail, icloud, yahoo

    private static let iCloudDomains: Set<String> = ["icloud.com", "me.com", "mac.com"]

    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .icloud: "iCloud Mail"
        case .yahoo: "Yahoo Mail"
        }
    }

    var host: String {
        switch self {
        case .gmail: "imap.gmail.com"
        case .icloud: "imap.mail.me.com"
        case .yahoo: "imap.mail.yahoo.com"
        }
    }

    var port: UInt16 { 993 }

    func username(for email: String) -> String {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard self == .icloud, parts.count == 2, !parts[0].isEmpty,
              Self.iCloudDomains.contains(parts[1].lowercased()) else { return email }
        return String(parts[0])
    }

    static func suggested(for email: String) -> Self {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return .gmail }
        let domain = String(parts[1])
        if iCloudDomains.contains(domain) { return .icloud }
        if (domain.hasPrefix("yahoo.") && domain.count > "yahoo.".count)
            || domain == "ymail.com" || domain == "rocketmail.com" { return .yahoo }
        return .gmail
    }

    static func gmailTwoStepURL(for email: String = "") -> URL {
        googleAccountURL(path: "/signinoptions/two-step-verification", email: email)
    }

    func appPasswordsURL(for email: String = "") -> URL {
        switch self {
        case .gmail: return Self.googleAccountURL(path: "/apppasswords", email: email)
        case .icloud: return URL(string: "https://account.apple.com/")!
        case .yahoo: return URL(string: "https://login.yahoo.com/myaccount/security/")!
        }
    }

    private static func googleAccountURL(path: String, email: String) -> URL {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return googleURL(path: path, host: "myaccount.google.com", account: account)
    }

    func webInboxURL(accountID: String = "", thread: UInt64? = nil) -> URL {
        switch self {
        case .gmail:
            return Self.googleURL(path: "/mail/u/", host: "mail.google.com", account: accountID,
                                  fragment: thread.map { "all/" + String($0, radix: 16) } ?? "inbox")
        case .icloud: return URL(string: "https://www.icloud.com/mail")!
        case .yahoo: return URL(string: "https://mail.yahoo.com")!
        }
    }

    private static func googleURL(path: String, host: String, account: String, fragment: String? = nil) -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = path
        if !account.isEmpty {
            url.queryItems = [URLQueryItem(name: "authuser", value: account)]
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        url.fragment = fragment
        return url.url!
    }

    func normalizeAppPassword(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !$0.properties.isWhitespace && !(self == .icloud && $0 == "-")
        }))
    }

    func looksLikeAppPassword(_ value: String) -> Bool {
        let bytes = normalizeAppPassword(value).utf8
        return bytes.count == 16 && bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    func passwordForLogin(_ normalized: String) -> String {
        guard self == .icloud, normalized.utf8.count == 16 else { return normalized }
        // Send iCloud's generated four groups, even if the user pasted them without separators.
        let bytes = Array(normalized.utf8)
        return stride(from: 0, to: bytes.count, by: 4)
            .map { String(decoding: bytes[$0..<($0 + 4)], as: UTF8.self) }.joined(separator: "-")
    }
}

struct MailAccount: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var colorIndex: Int
    var enabled: Bool
    var provider: MailProvider

    init(id: String, label: String, colorIndex: Int, enabled: Bool, provider: MailProvider = .gmail) {
        self.id = id
        self.label = label
        self.colorIndex = colorIndex
        self.enabled = enabled
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey { case id, label, colorIndex, enabled, provider }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        colorIndex = try values.decode(Int.self, forKey: .colorIndex)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        provider = try values.decodeIfPresent(MailProvider.self, forKey: .provider) ?? .gmail
    }
}

enum MailCredentialCheck {
    static func isEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !email.contains(where: \.isWhitespace)
            && !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func normalizeAppPassword(_ value: String) -> String {
        MailProvider.gmail.normalizeAppPassword(value)
    }

    static func looksLikeAppPassword(_ value: String) -> Bool {
        MailProvider.gmail.looksLikeAppPassword(value)
    }
}

struct MailContent: Equatable {
    let html: String?
    let text: String
}

/// What the inbox list draws for a sender: initials and a palette slot that stays the same for the same address on
/// every launch (Swift's `hashValue` is randomized per process, so this uses FNV-1a).
enum MailAvatar {
    static func paletteIndex(for address: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }

    /// One or two letters: first and last word of the display name, else the first letter of the address.
    /// Empty when nothing usable remains (the view then draws a person symbol).
    static func initials(name: String, address: String) -> String {
        func lead(_ word: Substring) -> Character? { word.first { $0.isLetter || $0.isNumber } }
        let plain = name.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let words = plain.split(whereSeparator: \.isWhitespace).filter { lead($0) != nil }
        if let first = words.first.flatMap(lead) {
            let last = words.count > 1 ? words.last.flatMap(lead) : nil
            return ([first] + (last.map { [$0] } ?? [])).map { String($0).uppercased() }.joined()
        }
        let local = address.split(separator: "@").first ?? ""
        return local.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? ""
    }
}

enum MailMIME {
    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)
    private static let entity = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)
    private static let parameterPattern = try! NSRegularExpression(
        pattern: #";\s*([\w-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;\s]+))"#
    )
    private static let crlf = Data([13, 10])
    private static let lf = Data([10])

    static func decodeHeader(_ header: String) -> String {
        let source = header.replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        let text = source as NSString
        var result = ""
        var end = 0
        var previousWasEncoded = false
        for word in encodedWord.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let payload = text.substring(with: word.range(at: 3))
            let encoding = text.substring(with: word.range(at: 2)).lowercased()
            let bytes = encoding == "b"
                ? Data(base64Encoded: payload)
                : quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            let gap = text.substring(with: NSRange(location: end, length: word.range.location - end))
            if !previousWasEncoded || bytes == nil || !gap.allSatisfy(\.isWhitespace) {
                result += gap
            }
            let charset = text.substring(with: word.range(at: 1)).split(separator: "*").first.map(String.init)
            result += bytes.map { decodeCharset($0, charset: charset) } ?? text.substring(with: word.range)
            previousWasEncoded = bytes != nil
            end = NSMaxRange(word.range)
        }
        return result + text.substring(from: end)
    }

    static func from(_ header: String) -> (name: String, address: String) {
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") else {
            return (value, value)
        }
        let address = String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        var name = String(value[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        }
        name = decodeHeader(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? address : name, address)
    }

    static func headers(_ bytes: Data) -> [String: String] {
        let text = decodeCharset(bytes, charset: nil)
            .replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            if fields[name] == nil {
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fields
    }

    static func plainText(_ message: Data) -> String {
        readablePart(message, depth: 0, partial: false)?.text ?? ""
    }

    static func content(_ message: Data) -> MailContent {
        let part = readablePart(message, depth: 0, partial: false)
        return MailContent(html: part?.html.map(sanitizeHTML), text: part?.text ?? "")
    }

    static func snippet(_ bytes: Data, headers: [String: String]) -> String {
        let text = readablePayload(bytes, fields: headers, depth: 0, partial: true)?.text ?? ""
        let compact = text.split {
            $0.isWhitespace || $0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
        }.joined(separator: " ")
        return String(compact.prefix(140))
    }

    private struct TextPart {
        let text: String
        let isPlain: Bool
        var html: HTMLPart? = nil
    }

    private struct HTMLPart {
        let source: String
        var images: [String: InlineImage] = [:]
    }

    private struct InlineImage {
        let mime: String
        let bytes: Data
        let encoding: String?
    }

    private static func splitPart(_ message: Data, partial: Bool) -> (fields: [String: String], bytes: Data)? {
        if message.starts(with: crlf) || message.starts(with: lf) {
            return ([:], message.dropFirst(message.first == 13 ? 2 : 1))
        }
        let separator = [Data([13, 10, 13, 10]), Data([10, 10])].compactMap { message.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        if let separator {
            return (headers(message[..<separator.lowerBound]), message[separator.upperBound...])
        }
        let firstLine = message.prefix { $0 != 10 && $0 != 13 }
        if let colon = firstLine.firstIndex(of: 58),
           colon > firstLine.startIndex, firstLine[..<colon].allSatisfy({ (33...126).contains($0) }),
           partial || headers(firstLine)["content-type"] != nil || headers(firstLine)["content-disposition"] != nil {
            return nil
        }
        return ([:], message)
    }

    private static func readablePart(_ message: Data, depth: Int, partial: Bool) -> TextPart? {
        guard depth < 30, let part = splitPart(message, partial: partial) else { return nil }
        return readablePayload(part.bytes, fields: part.fields, depth: depth, partial: partial)
    }

    private static func readablePayload(_ bytes: Data, fields: [String: String], depth: Int, partial: Bool,
                                        allowForwardedAttachment: Bool = false) -> TextPart? {
        guard depth < 30 else { return nil }
        let contentType = fields["content-type"] ?? "text/plain"
        let type = mimeValue(contentType)
        let isForwarded = type == "message/rfc822" || type == "message/global"
        if fields["content-disposition"].map(mimeValue) == "attachment",
           !(isForwarded && allowForwardedAttachment) { return nil }

        if isForwarded {
            guard let decoded = decodeTransfer(bytes, encoding: fields["content-transfer-encoding"],
                                               partial: partial) else { return nil }
            return readablePart(decoded, depth: depth + 1, partial: partial)
        }
        if type.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType), !boundary.isEmpty else { return nil }
            let children = multipart(bytes, boundary: boundary, partial: partial).map {
                splitPart($0, partial: partial)
            }
            if type == "multipart/related" {
                let root: Int?
                if let id = parameter("start", in: contentType).map(contentID) {
                    root = children.firstIndex { $0?.fields["content-id"].map(contentID) == id }
                } else {
                    root = children.indices.first
                }
                guard let root, let part = children[root],
                      var result = readablePayload(part.bytes, fields: part.fields, depth: depth + 1,
                                                   partial: partial) else { return nil }

                if !partial, var html = result.html {
                    for (index, child) in children.enumerated() where index != root {
                        guard let child, let id = child.fields["content-id"].map(contentID),
                              let mime = child.fields["content-type"].map(mimeValue),
                              mime.hasPrefix("image/"), html.images[id] == nil else { continue }
                        html.images[id] = InlineImage(mime: mime, bytes: child.bytes,
                                                     encoding: child.fields["content-transfer-encoding"])
                    }
                    result.html = html
                }
                return result
            }

            let parts = children.compactMap { child in
                child.flatMap { readablePayload($0.bytes, fields: $0.fields, depth: depth + 1, partial: partial) }
            }
            let readable = parts.filter { !$0.text.isEmpty }
            if type == "multipart/alternative" {
                let text = readable.first(where: \.isPlain) ?? readable.last
                let html = parts.reversed().compactMap(\.html).first
                guard text != nil || html != nil else { return nil }
                return TextPart(text: text?.text ?? "", isPlain: text?.isPlain ?? false, html: html)
            }
            let html = parts.compactMap(\.html).first
            if readable.isEmpty && (partial || html == nil) {
                // Forward as attachment is a body fallback when the sender added no readable message.
                for child in children.compactMap({ $0 })
                    where child.fields["content-disposition"].map(mimeValue) == "attachment" {
                    if let forwarded = readablePayload(child.bytes, fields: child.fields, depth: depth + 1,
                                                       partial: partial, allowForwardedAttachment: true) {
                        return forwarded
                    }
                }
            }
            guard !readable.isEmpty || html != nil else { return nil }
            return TextPart(text: readable.map(\.text).joined(separator: "\n\n"),
                            isPlain: readable.allSatisfy(\.isPlain), html: html)
        }
        guard type == "text/plain" || type == "text/html",
              parameter("name", in: contentType) == nil,
              let decoded = decodeTransfer(bytes, encoding: fields["content-transfer-encoding"],
                                           partial: partial) else { return nil }
        let raw = decodeCharset(decoded, charset: parameter("charset", in: contentType), partial: partial)
        let isPlain = type == "text/plain"
        let text = isPlain ? raw.replacingOccurrences(of: "\r\n", with: "\n") : htmlText(raw)
        return TextPart(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isPlain: isPlain,
                        html: isPlain || partial ? nil : HTMLPart(source: raw))
    }

    private static func contentID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
    }

    private static func mimeValue(_ value: String) -> String {
        value.prefix(while: { $0 != ";" }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        let text = value as NSString
        for match in parameterPattern.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            guard text.substring(with: match.range(at: 1)).lowercased() == name else { continue }
            if match.range(at: 2).location != NSNotFound {
                return text.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
            return text.substring(with: match.range(at: 3))
        }
        return nil
    }

    private static func multipart(_ bytes: Data, boundary: String, partial: Bool) -> [Data] {
        let marker = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var start: Data.Index?
        var lineStart = bytes.startIndex
        while lineStart < bytes.endIndex {
            let lineBreak = bytes.range(of: lf, in: lineStart..<bytes.endIndex)
            let lineEnd = lineBreak?.lowerBound ?? bytes.endIndex
            let next = lineBreak?.upperBound ?? bytes.endIndex
            let line = bytes[lineStart..<lineEnd]
            let suffix = line.dropFirst(marker.count)
            let closing = suffix.starts(with: [45, 45])
            let padding = closing ? suffix.dropFirst(2) : suffix
            let delimiter = line.starts(with: marker) && padding.allSatisfy { $0 == 32 || $0 == 9 || $0 == 13 }
            let cutDelimiter = partial && lineBreak == nil && line.starts(with: [45, 45])
                && (marker.starts(with: line) || (line.starts(with: marker) && suffix.elementsEqual([45])))
            if delimiter || cutDelimiter {
                if let start {
                    var end = lineStart
                    if end > start, bytes[end - 1] == 10 { end -= 1 }
                    if end > start, bytes[end - 1] == 13 { end -= 1 }
                    parts.append(bytes[start..<end])
                }
                if closing || cutDelimiter { return parts }
                start = next
            }
            lineStart = next
        }
        if let start, start < bytes.endIndex { parts.append(bytes[start...]) }
        return parts
    }

    static func decodeTransfer(_ bytes: Data, encoding: String?, partial: Bool = false) -> Data? {
        switch encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quoted-printable":
            return quotedPrintable(bytes, partial: partial)
        case "base64":
            var compact = Data(bytes.filter { ![9, 10, 13, 32].contains($0) })
            if partial && !compact.contains(61) {
                compact.removeLast(compact.count % 4 == 1 ? 1 : 0)
                compact.append(contentsOf: repeatElement(61, count: (4 - compact.count % 4) % 4))
            } else if partial, compact.last == 61, compact.count % 4 == 3 {
                compact.append(61)
            }
            return Data(base64Encoded: compact)
        default:
            return bytes
        }
    }

    private static func quotedPrintable(_ bytes: Data, partial: Bool = false) -> Data {
        var result = Data()
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if byte == 61, index < bytes.endIndex {
                if bytes[index] == 10 {
                    index += 1
                    continue
                }
                if index + 1 < bytes.endIndex {
                    if bytes[index] == 13, bytes[index + 1] == 10 {
                        index += 2
                        continue
                    }
                    if let high = hex(bytes[index]), let low = hex(bytes[index + 1]) {
                        result.append(high * 16 + low)
                        index += 2
                        continue
                    }
                }
            }
            if partial && byte == 61 && bytes.endIndex - index < 2 { break }
            result.append(byte)
        }
        return result
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    static func decodeCharset(_ bytes: Data, charset: String?, partial: Bool = false) -> String {
        let charset = charset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch charset {
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
        case "windows-1252", "windows1252", "cp1252":
            return String(String.UnicodeScalarView(bytes.map { windowsScalar($0) }))
        case "utf-16", "utf16":
            if let text = String(data: bytes, encoding: .utf16) { return text }
        case "utf-8", "utf8", nil: break
        default:
            if let charset {
                let id = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                if id != kCFStringEncodingInvalidId {
                    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(id))
                    if let text = String(data: bytes, encoding: encoding) { return text }
                }
            }
        }

        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        if charset == "utf-8" || charset == "utf8" {
            if partial, let lead = bytes.suffix(3).lastIndex(where: { $0 & 0xC0 != 0x80 }) {
                let length: Int
                switch bytes[lead] {
                case 0xC2...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF4: length = 4
                default: length = 0
                }
                if bytes.endIndex - lead < length, let prefix = String(data: bytes[..<lead], encoding: .utf8) {
                    return prefix
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(String.UnicodeScalarView(bytes.map { windowsScalar($0) }))
    }

    private static let windowsControls: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178
    ]

    private static func windowsScalar(_ byte: UInt8) -> UnicodeScalar {
        guard (128...159).contains(byte) else { return UnicodeScalar(byte) }
        return UnicodeScalar(windowsControls[Int(byte) - 128])!
    }

    private struct HTMLTag {
        let name: String
        let closing: Bool
        var attributes: [(name: String, value: String?)] = []
    }

    private enum HTMLToken {
        case text(String)
        case tag(HTMLTag)
        case ignored
    }

    /// Reads ASCII HTML syntax on UTF-8 bytes. Markup is reconstructed from the parsed tokens.
    private struct HTMLScanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ source: String) { bytes = Array(source.utf8) }

        mutating func next(attributes: Bool = false) -> HTMLToken? {
            guard index < bytes.count else { return nil }
            let start = index
            if bytes[index] != 60 {
                while index < bytes.count && bytes[index] != 60 { index += 1 }
                return .text(string(start..<index))
            }

            index += 1
            if bytes[index...].starts(with: [33, 45, 45]) {
                index += 3
                while index < bytes.count {
                    if bytes[index...].starts(with: [45, 45, 62]) {
                        index += 3
                        return .ignored
                    }
                    index += 1
                }
                return .ignored
            }
            if current == 33 || current == 63 {
                while index < bytes.count && current != 62 { index += 1 }
                if index < bytes.count { index += 1 }
                return .ignored
            }

            let closing = current == 47
            if closing { index += 1 }
            guard let first = current, (65...90).contains(first) || (97...122).contains(first) else {
                index = start + 1
                return .text("<")
            }
            let nameStart = index
            while let byte = current, !Self.space(byte), byte != 47, byte != 62 { index += 1 }
            var tag = HTMLTag(name: string(nameStart..<index).lowercased(), closing: closing)
            while let byte = current {
                if byte == 62 {
                    index += 1
                    return .tag(tag)
                }
                if Self.space(byte) || byte == 47 {
                    index += 1
                    continue
                }
                let attributeStart = index
                repeat { index += 1 } while current.map { !Self.space($0) && ![47, 61, 62].contains($0) } == true
                let attributeEnd = index
                skipSpace()
                var value: String?
                if current == 61 {
                    index += 1
                    skipSpace()
                    if let quote = current, quote == 34 || quote == 39 {
                        index += 1
                        let valueStart = index
                        while let byte = current, byte != quote { index += 1 }
                        if attributes { value = string(valueStart..<index) }
                        if index < bytes.count { index += 1 }
                    } else {
                        let valueStart = index
                        while let byte = current, !Self.space(byte), byte != 62 { index += 1 }
                        if attributes { value = string(valueStart..<index) }
                    }
                }
                if attributes && !closing {
                    tag.attributes.append((string(attributeStart..<attributeEnd).lowercased(), value))
                }
            }
            return .ignored
        }

        mutating func takeRawText(until name: String, capture: Bool = false) -> String {
            let start = index
            let endTag = Array(name.utf8)
            while index < bytes.count {
                let nameStart = index + 2
                let nameEnd = nameStart + endTag.count
                if current == 60, nameEnd < bytes.count, bytes[index + 1] == 47,
                   zip(bytes[nameStart..<nameEnd], endTag).allSatisfy({
                       ((65...90).contains($0.0) ? $0.0 + 32 : $0.0) == $0.1
                   }), Self.space(bytes[nameEnd]) || bytes[nameEnd] == 62 || bytes[nameEnd] == 47 {
                    let end = index
                    _ = next()
                    return capture ? string(start..<end) : ""
                }
                index += 1
            }
            return capture ? string(start..<index) : ""
        }

        private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func skipSpace() {
            while let byte = current, Self.space(byte) { index += 1 }
        }

        private static func space(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 12 || byte == 13
        }

        private func string(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }
    }

    private static let suppressedHTML: Set<String> = [
        "script", "iframe", "object", "template", "svg", "math", "title", "textarea",
        "xmp", "noembed", "noframes", "noscript"
    ]
    private static let paragraphTags: Set<String> = [
        "p", "div", "blockquote", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6",
        "table", "ul", "ol", "hr"
    ]

    static func htmlText(_ html: String) -> String {
        var scanner = HTMLScanner(html)
        var inHead = false
        var text = ""
        while let token = scanner.next() {
            switch token {
            case let .text(value) where !inHead:
                text += String(value.map { $0.isNewline ? " " : $0 })
            case let .tag(tag):
                if !tag.closing && (tag.name == "style" || suppressedHTML.contains(tag.name)) {
                    _ = scanner.takeRawText(until: tag.name)
                } else if tag.name == "head" {
                    inHead = !tag.closing
                } else if tag.name == "body" {
                    inHead = false
                } else if !inHead {
                    if paragraphTags.contains(tag.name) { text += "\n\n" }
                    if ["br", "li", "tr"].contains(tag.name) { text += "\n" }
                    if tag.closing && ["td", "th"].contains(tag.name) { text += " " }
                }
            default: break
            }
        }

        var lines: [String] = []
        for line in decodeEntities(text).components(separatedBy: "\n") {
            let compact = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !compact.isEmpty || (lines.last.map { !$0.isEmpty } ?? false) {
                lines.append(compact)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let safeTags: Set<String> = paragraphTags.union([
        "a", "abbr", "address", "b", "bdi", "bdo", "big", "br", "caption", "center", "cite", "code",
        "col", "colgroup", "dd", "del", "details", "dfn", "dl", "dt", "em", "figcaption", "figure",
        "font", "footer", "header", "i", "img", "ins", "kbd", "li", "main", "mark", "pre", "q",
        "s", "samp", "small", "span", "strike", "strong", "sub", "summary", "sup", "tbody", "td",
        "tfoot", "th", "thead", "time", "tr", "tt", "u", "var", "wbr"
    ])
    private static let safeAttributes: Set<String> = [
        "align", "alt", "aria-hidden", "aria-label", "bgcolor", "border", "cellpadding", "cellspacing",
        "class", "color", "colspan", "dir", "face", "height", "hidden", "hspace", "id", "lang",
        "role", "rowspan", "scope", "size", "span", "start", "style", "title", "type", "valign",
        "value", "vspace", "width"
    ]
    private static let imageType = try! NSRegularExpression(pattern: #"\Aimage/[a-z0-9][a-z0-9.+-]*\z"#)

    private static func sanitizeHTML(_ part: HTMLPart) -> String {
        let policy = "default-src 'none'; style-src 'unsafe-inline'; img-src http: https: data:; "
            + "font-src data:; base-uri 'none'; form-action 'none'"
        var head = #"<meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content=""#
            + policy + "\">"
        var html = "<html>"
        var body = "<body>"
        var content = ""
        var inHead = false
        var images = InlineImages(parts: part.images)
        var scanner = HTMLScanner(part.source)
        while let token = scanner.next(attributes: true) {
            switch token {
            case let .text(value) where !inHead:
                content += value.replacingOccurrences(of: "<", with: "&lt;")
            case let .tag(tag):
                if !tag.closing && suppressedHTML.contains(tag.name) {
                    _ = scanner.takeRawText(until: tag.name)
                } else if tag.name == "style", !tag.closing {
                    let css = scanner.takeRawText(until: "style", capture: true)
                    guard let css = images.sanitizeCSS(css) else { continue }
                    let media = tag.attributes.first { $0.name == "media" }?.value
                    let opening = media.map { "<style media=\"" + escapeAttribute($0) + "\">" } ?? "<style>"
                    if inHead { head += opening + css + "</style>" }
                    else { content += opening + css + "</style>" }
                } else if tag.name == "head" {
                    inHead = !tag.closing
                } else if (!tag.closing && ["html", "body"].contains(tag.name))
                            || (!inHead && safeTags.contains(tag.name)) {
                    if tag.closing {
                        content += "</\(tag.name)>"
                        continue
                    }
                    var opening = "<" + tag.name
                    var seen: Set<String> = []
                    for attribute in tag.attributes where seen.insert(attribute.name).inserted {
                        let name = attribute.name
                        var value = decodeEntities(attribute.value ?? "")
                        if safeAttributes.contains(name) {
                            if name == "style" {
                                guard let css = images.sanitizeCSS(value) else { continue }
                                value = css
                            }
                        } else if (name == "src" && tag.name == "img") || name == "background" {
                            let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if url.lowercased().hasPrefix("cid:") {
                                guard let inlined = images.resolve(url) else { continue }
                                value = inlined
                            } else if !allowedURL(value, image: true) { continue }
                        } else if name == "href" && tag.name == "a" {
                            guard allowedURL(value, image: false) else { continue }
                        } else {
                            continue
                        }
                        if ["src", "background", "href"].contains(name) {
                            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if value.hasPrefix("//") { value = "https:" + value }
                        }
                        opening += " " + name + "=\"" + escapeAttribute(value) + "\""
                    }
                    opening += ">"
                    switch tag.name {
                    case "html": html = opening
                    case "body":
                        body = opening
                        inHead = false
                    default: content += opening
                    }
                }
            default: break
            }
        }
        return "<!doctype html>" + html + "<head>" + head + "</head>" + body + content + "</body></html>"
    }

    private struct InlineImages {
        private static let cssCID = try! NSRegularExpression(
            pattern: #"(?i)\burl\(\s*(?:"(cid:[^"]*)"|'(cid:[^']*)'|(cid:[^\s)]*))\s*\)"#
        )
        let parts: [String: InlineImage]
        private var budget = 10 * 1024 * 1024
        private var urls: [String: String] = [:]

        init(parts: [String: InlineImage]) { self.parts = parts }

        mutating func resolve(_ cidURL: String) -> String? {
            let cid = cidURL.dropFirst(4)
            let id = contentID(cid.removingPercentEncoding ?? String(cid))
            let url: String
            if let cached = urls[id] {
                url = cached
            } else {
                guard let image = parts[id], image.bytes.count <= 2 * budget,
                      imageType.firstMatch(in: image.mime, range: NSRange(image.mime.startIndex..., in: image.mime)) != nil,
                      let bytes = decodeTransfer(image.bytes, encoding: image.encoding), !bytes.isEmpty,
                      bytes.count <= budget * 3 / 4 else { return nil }
                url = "data:\(image.mime);base64," + bytes.base64EncodedString()
            }
            guard url.utf8.count <= budget else { return nil }
            budget -= url.utf8.count
            urls[id] = url
            return url
        }

        mutating func sanitizeCSS(_ css: String) -> String? {
            let normalized = normalizedURL(css)
            guard !normalized.contains("javascript:"), !normalized.contains("file://") else { return nil }
            guard !parts.isEmpty, css.range(of: "cid:", options: .caseInsensitive) != nil else { return css }
            let source = css as NSString
            var result = ""
            var end = 0
            for match in Self.cssCID.matches(in: css, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: end, length: match.range.location - end))
                if let range = (1...3).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }),
                   let url = resolve(source.substring(with: range)) {
                    result += "url(\"\(url)\")"
                } else {
                    result += "none"
                }
                end = NSMaxRange(match.range)
            }
            return result + source.substring(from: end)
        }
    }

    private static func normalizedURL(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7f }).lowercased()
    }

    private static func allowedURL(_ value: String, image: Bool) -> Bool {
        let url = normalizedURL(value)
        if url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("//") { return true }
        if image { return url.hasPrefix("data:image/") }
        return url.hasPrefix("mailto:")
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "apos": "'", "quot": "\"", "lt": "<", "gt": ">", "nbsp": " ",
        "iexcl": "¡", "iquest": "¿", "aacute": "á", "eacute": "é", "iacute": "í",
        "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "uuml": "ü", "ccedil": "ç",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "aring": "å", "aelig": "æ",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "cent": "¢",
        "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "hellip": "…",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "", "zwnj": "", "zwj": "\u{200D}"
    ]

    private static func decodeEntities(_ html: String) -> String {
        guard html.contains("&") else { return html }
        let text = html as NSString
        let result = NSMutableString(string: html)
        for match in entity.matches(in: html, range: NSRange(location: 0, length: text.length)).reversed() {
            let name = text.substring(with: match.range(at: 1))
            let replacement: String?
            if name.hasPrefix("#") {
                let isHex = name.dropFirst().first?.lowercased() == "x"
                let code = UInt32(name.dropFirst(isHex ? 2 : 1), radix: isHex ? 16 : 10)
                replacement = code.map { code in
                    if (128...159).contains(code) { return String(windowsScalar(UInt8(code))) }
                    return code == 0 ? "�" : UnicodeScalar(code).map(String.init) ?? "�"
                }
            } else {
                replacement = namedEntities[name] ?? namedEntities[name.lowercased()].map {
                    name.first?.isUppercase == true && $0.count == 1 ? $0.uppercased() : $0
                }
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}

enum MailServerError: Error, Equatable {
    case authenticationFailed, appPasswordRequired, blocked, offline

    static func classify(_ serverText: String) -> Self {
        let text = serverText.lowercased()
        if text.contains("imap access is disabled") || text.contains("web login required")
            || text.contains("not enabled for imap")
            || text.contains("[authorizationfailed]") || text.contains("imap is disabled")
            || (text.contains("administrator") && (text.contains("imap") || text.contains("app password") || text.contains("[alert]"))) {
            return .blocked
        }
        if text.contains("application-specific password required") || text.contains("app-specific password required")
            || text.contains("app password required") { return .appPasswordRequired }
        if text.contains("[authenticationfailed]") || text.contains("invalid credentials")
            || text.contains("username and password not accepted") || text.contains("login failed") {
            return .authenticationFailed
        }
        return .offline
    }
}

enum MailIMAPToken: Equatable {
    case atom(String)
    case quoted(String)
    case literal(Data)
    case openList
    case closeList

    var string: String? {
        switch self {
        case let .atom(value), let .quoted(value): return value
        case let .literal(value): return String(data: value, encoding: .utf8)
        default: return nil
        }
    }

    var bytes: Data? {
        switch self {
        case let .literal(bytes): return bytes
        case let .quoted(text): return Data(text.utf8)
        default: return nil
        }
    }
}

struct MailIMAPResponse {
    fileprivate enum Segment {
        case line(Data)
        case literal(Data)
    }

    fileprivate let segments: [Segment]
    let byteCount: Int

    var line: String {
        guard case let .line(bytes)? = segments.first else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    var tokens: [MailIMAPToken] {
        var result: [MailIMAPToken] = []
        for segment in segments {
            switch segment {
            case let .line(bytes): Self.tokenize(bytes, into: &result)
            case let .literal(bytes): result.append(.literal(bytes))
            }
        }
        return result
    }

    private static func tokenize(_ bytes: Data, into tokens: inout [MailIMAPToken]) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            defer { index += 1 }
            switch bytes[index] {
            case 32, 9: break
            case 40: tokens.append(.openList)
            case 41: tokens.append(.closeList)
            case 34:
                var value = Data()
                index += 1
                while index < bytes.endIndex, bytes[index] != 34 {
                    if bytes[index] == 92, index + 1 < bytes.endIndex { index += 1 }
                    value.append(bytes[index])
                    index += 1
                }
                tokens.append(.quoted(String(decoding: value, as: UTF8.self)))
            default:
                let start = index
                var inSection = false
                while index < bytes.endIndex {
                    let byte = bytes[index]
                    if !inSection && (byte == 32 || byte == 9 || byte == 40 || byte == 41) { break }
                    if byte == 91 && index - start == 4 { inSection = String(decoding: bytes[start..<index], as: UTF8.self).uppercased() == "BODY" }
                    if byte == 93 { inSection = false }
                    index += 1
                }
                tokens.append(.atom(String(decoding: bytes[start..<index], as: UTF8.self)))
                index -= 1
            }
        }
    }

    var fetch: MailIMAPFetch? { MailIMAPFetch(tokens) }
    var mailbox: MailIMAPMailbox? { MailIMAPMailbox(tokens) }
}

/// Frames IMAP responses without treating CRLF or tag-like text inside a literal as protocol.
struct MailIMAPFramer {
    enum Failure: Error { case responseTooLarge }

    private static let crlf = Data([13, 10])
    private let maxResponseSize: Int
    private var frameStart = 0
    private var buffer = Data()
    private var cursor = 0
    private var scan = 0
    private var literalSize: Int?
    private var segments: [MailIMAPResponse.Segment] = []

    init(maxResponseSize: Int = 64 * 1024 * 1024) { self.maxResponseSize = maxResponseSize }

    mutating func append(_ bytes: Data) { buffer.append(bytes) }

    mutating func next() throws -> MailIMAPResponse? {
        while true {
            if let size = literalSize {
                guard buffer.count - cursor >= size else { return nil }
                segments.append(.literal(buffer[cursor..<(cursor + size)]))
                cursor += size
                scan = cursor
                literalSize = nil
            }
            guard let end = buffer.range(of: Self.crlf, in: scan..<buffer.endIndex) else {
                guard buffer.endIndex - frameStart < maxResponseSize else { throw Failure.responseTooLarge }
                scan = max(cursor, buffer.endIndex - 1)
                return nil
            }
            guard end.upperBound - frameStart <= maxResponseSize else { throw Failure.responseTooLarge }
            let line = buffer[cursor..<end.lowerBound]
            cursor = end.upperBound
            scan = cursor
            let hasLiterals = !segments.isEmpty || Self.canContainLiteral(line)
            if hasLiterals, let marker = Self.literalMarker(line) {
                guard let size = Int(marker.size), size <= maxResponseSize - (cursor - frameStart) else {
                    throw Failure.responseTooLarge
                }
                segments.append(.line(line[..<marker.start]))
                literalSize = size
            } else {
                segments.append(.line(line))
                let response = MailIMAPResponse(segments: segments, byteCount: cursor - frameStart)
                if cursor == buffer.endIndex || (cursor >= 65536 && cursor >= buffer.count / 2) {
                    buffer = Data(buffer[cursor...])
                    cursor = 0
                    scan = 0
                }
                frameStart = cursor
                segments.removeAll(keepingCapacity: true)
                return response
            }
        }
    }

    private static func canContainLiteral(_ line: Data) -> Bool {
        guard line.starts(with: [42, 32]) else { return false }
        let prefix = line.prefix(40).split(separator: 32, maxSplits: 3)
        guard prefix.count >= 2 else { return false }
        let kind = String(decoding: prefix[1], as: UTF8.self).uppercased()
        if ["LIST", "LSUB", "STATUS", "ID", "NAMESPACE", "METADATA", "ACL"].contains(kind) { return true }
        return prefix.count >= 3 && UInt32(kind) != nil && String(decoding: prefix[2], as: UTF8.self).uppercased() == "FETCH"
    }

    private static func literalMarker(_ line: Data) -> (start: Int, size: String)? {
        guard line.last == 125, let start = line.lastIndex(of: 123), start > line.startIndex,
              line[start - 1] == 32 || line[start - 1] == 40 else { return nil }
        var digits = line[(start + 1)..<(line.endIndex - 1)]
        if digits.last == 43 { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return (start, String(decoding: digits, as: UTF8.self))
    }
}

struct MailIMAPFetch {
    let uid: UInt32?
    let flags: Set<String>
    let threadID: UInt64?
    let messageID: UInt64?
    let internalDate: Date?
    let messageSize: UInt64?
    /// The BODYSTRUCTURE value's tokens, from its opening parenthesis (see MailBodyStructure.parse).
    let structureTokens: [MailIMAPToken]?
    private let attributes: [String: MailIMAPToken]

    init?(_ tokens: [MailIMAPToken]) {
        guard tokens.count >= 5, tokens[0] == .atom("*"), tokens[2].string?.uppercased() == "FETCH",
              tokens[3] == .openList else { return nil }
        var attributes: [String: MailIMAPToken] = [:]
        var flags: Set<String> = []
        var structure: [MailIMAPToken]?
        var index = 4
        while index + 1 < tokens.count, case let .atom(key) = tokens[index] {
            let name = key.uppercased()
            index += 1
            let value = tokens[index]
            index += 1
            if value == .openList {
                let listStart = index - 1
                var depth = 1
                while index < tokens.count, depth > 0 {
                    let element = tokens[index]
                    if element == .openList { depth += 1 }
                    if element == .closeList { depth -= 1 }
                    if name == "FLAGS", depth == 1, let flag = element.string { flags.insert(flag.uppercased()) }
                    index += 1
                }
                if name == "BODYSTRUCTURE", depth == 0 { structure = Array(tokens[listStart..<index]) }
            } else {
                attributes[Self.sectionKey(name)] = value
            }
        }
        self.attributes = attributes
        self.flags = flags
        structureTokens = structure
        uid = attributes["UID"]?.string.flatMap(UInt32.init)
        threadID = attributes["X-GM-THRID"]?.string.flatMap(UInt64.init)
        messageID = attributes["X-GM-MSGID"]?.string.flatMap(UInt64.init)
        messageSize = attributes["RFC822.SIZE"]?.string.flatMap(UInt64.init)
        internalDate = attributes["INTERNALDATE"]?.string.flatMap(Self.date)
    }

    func body(_ section: String, partial: Bool = false) -> Data? {
        let key = "BODY[\(section.uppercased())]"
        return attributes[Self.sectionKey(partial ? key + "<0>" : key)]?.bytes
    }

    private static func sectionKey(_ key: String) -> String {
        guard key.hasPrefix("BODY[HEADER.FIELDS ("), key.hasSuffix(")]") else { return key }
        let fields = key.dropFirst("BODY[HEADER.FIELDS (".count).dropLast(2)
        return "BODY[HEADER.FIELDS (" + fields.split(whereSeparator: \.isWhitespace).sorted().joined(separator: " ") + ")]"
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}

struct MailIMAPMailbox {
    let name: String
    let flags: Set<String>

    init?(_ tokens: [MailIMAPToken]) {
        guard tokens.count >= 6, tokens[0] == .atom("*"), tokens[1].string?.uppercased() == "LIST",
              tokens[2] == .openList, let end = tokens[3...].firstIndex(of: .closeList),
              end + 2 < tokens.count, let name = tokens[end + 2].string else { return nil }
        self.name = name
        flags = Set(tokens[3..<end].compactMap { $0.string?.uppercased() })
    }

    private var isSelectable: Bool { !flags.contains("\\NOSELECT") && !flags.contains("\\NONEXISTENT") }
    var isAll: Bool { isSelectable && flags.contains("\\ALL") }
    var isTrash: Bool { isSelectable && flags.contains("\\TRASH") }

    static func archive(in boxes: [Self], provider: MailProvider) -> Self? {
        if provider == .gmail { return boxes.first(where: \.isAll) }
        return boxes.first { $0.isSelectable && $0.flags.contains("\\ARCHIVE") }
            ?? named(["archive", "archivo"], in: boxes)
    }

    static func trash(in boxes: [Self]) -> Self? {
        boxes.first(where: \.isTrash) ?? named(["trash", "deleted messages", "papelera"], in: boxes)
    }

    private static func named(_ names: Set<String>, in boxes: [Self]) -> Self? {
        boxes.first { $0.isSelectable && names.contains($0.name.lowercased()) }
    }
}
