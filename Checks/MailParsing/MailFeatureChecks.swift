import Darwin
import Foundation

// Oracle checks for attachments, bulk actions on selected rows and older pages (df6e985), written from what the person
// and the server should see. They reuse FakeIMAPWorld / MailHarness from MailFastChecks.swift.

// MARK: Fixtures

let presupuestoName = "Presupuesto año.pdf"
let presupuestoWord = "=?UTF-8?B?\(Data(presupuestoName.utf8).base64EncodedString())?="

/// A Gmail-style message with one of each kind of part. Sections:
/// 1 related (1.1 html body, 1.2 cid logo), 2 PDF (RFC 2047 name), 3 text attachment (RFC 2231 UTF-8 name, QP),
/// 4 octet-stream (RFC 2231 ISO-8859-1 continuation), 5 forwarded message/rfc822 (no name), 6 unnamed zip.
let fixtureAttachments = crlfData("""
    From: Equipo <equipo@example.test>
    Subject: Documentos
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="m"

    --m
    Content-Type: multipart/related; boundary="r"

    --r
    Content-Type: text/html; charset=UTF-8

    <p>Hola</p><img src="cid:logo@x">
    --r
    Content-Type: image/png; name="logo.png"
    Content-ID: <logo@x>
    Content-Disposition: inline; filename="logo.png"
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --r--
    --m
    Content-Type: application/pdf; name="\(presupuestoWord)"
    Content-Disposition: attachment; filename="\(presupuestoWord)"
    Content-Transfer-Encoding: base64

    JVBERi0xLjQK
    --m
    Content-Type: text/plain; charset=UTF-8
    Content-Disposition: attachment; filename*=utf-8''caf%C3%A9%20men%C3%BA.txt
    Content-Transfer-Encoding: quoted-printable

    Caf=C3=A9 =
    con leche
    --m
    Content-Type: application/octet-stream
    Content-Disposition: attachment;
     filename*0*=iso-8859-1''Reuni%F3n%20;
     filename*1="final.bin"

    AAAA
    --m
    Content-Type: message/rfc822

    From: a@example.test
    Subject: Reenviado

    Texto reenviado
    --m
    Content-Type: application/zip
    Content-Transfer-Encoding: base64

    UEsDBA==
    --m--
    """)
let fixtureAttachmentsStructure = #"((("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 34 1 NIL NIL NIL NIL)("IMAGE" "PNG" ("NAME" "logo.png") "<logo@x>" NIL "BASE64" 12 NIL ("INLINE" ("FILENAME" "logo.png")) NIL NIL) "RELATED" ("BOUNDARY" "r") NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "\#(presupuestoWord)") NIL NIL "BASE64" 12 NIL ("ATTACHMENT" ("FILENAME" "\#(presupuestoWord)")) NIL NIL)("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 22 2 NIL ("ATTACHMENT" ("FILENAME*" "utf-8''caf%C3%A9%20men%C3%BA.txt")) NIL NIL)("APPLICATION" "OCTET-STREAM" NIL NIL NIL "7BIT" 4 NIL ("ATTACHMENT" ("FILENAME*0*" "iso-8859-1''Reuni%F3n%20" "FILENAME*1" "final.bin")) NIL NIL)("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 50 (NIL "Reenviado" NIL NIL NIL NIL NIL NIL NIL NIL) ("TEXT" "PLAIN" NIL NIL NIL "7BIT" 15 1 NIL NIL NIL NIL) 3 NIL NIL NIL NIL)("APPLICATION" "ZIP" NIL NIL NIL "BASE64" 8 NIL NIL NIL NIL) "MIXED" ("BOUNDARY" "m") NIL NIL NIL)"#

private func withoutSize(_ list: [MailAttachment]) -> [String] {
    list.map { "\($0.section)|\($0.filename)|\($0.mime)|\($0.encoding ?? "-")" }
}

// MARK: (1) Attachments: listing and decoding (pure)

func checkAttachmentLists() {
    guard let root = parsedStructure(fixtureAttachmentsStructure) else { expect("ATT fixture structure parses", false); return }
    let list = MailAttachmentList.from(structure: root)
    let sections = list.map(\.section)
    expect("ATT list: body text and the cid logo of the related part are not attachments",
           !sections.contains("1.1") && !sections.contains("1.2"))
    expect("ATT list: the PDF, the text attachment, the binary, the forwarded message and the unnamed zip are listed in order",
           sections == ["2", "3", "4", "5", "6"])
    let bySection = Dictionary(uniqueKeysWithValues: list.map { ($0.section, $0) })
    expect("ATT list: RFC 2047 encoded-word file name is decoded", bySection["2"]?.filename == presupuestoName
               && bySection["2"]?.mime == "application/pdf" && bySection["2"]?.encoding == "base64")
    expect("ATT list: RFC 2231 UTF-8 percent-encoded file name is decoded", bySection["3"]?.filename == "café menú.txt"
               && bySection["3"]?.encoding == "quoted-printable")
    expect("ATT list: RFC 2231 continuation with an ISO-8859-1 charset is joined and decoded",
           bySection["4"]?.filename == "Reunión final.bin" && bySection["4"]?.encoding == nil)
    expect("ATT list: a forwarded message/rfc822 without a name is listed as an .eml file",
           bySection["5"]?.mime == "message/rfc822" && bySection["5"]?.filename.hasSuffix(".eml") == true)
    expect("ATT list: an unnamed binary part gets a readable fallback name that mentions its part",
           bySection["6"].map { !$0.filename.isEmpty && $0.filename.contains("6") && $0.mime == "application/zip" } == true)
    expect("ATT list: sizes come from BODYSTRUCTURE", bySection["2"]?.size == 12 && bySection["4"]?.size == 4)

    let fromRaw = MailAttachmentList.from(message: fixtureAttachments)
    expect("ATT list from the whole message matches the BODYSTRUCTURE list (sections, names, types, encodings)",
           withoutSize(fromRaw) == withoutSize(list))
    if let mixed = parsedStructure(fixtureMixedStructure) {
        expect("ATT list of the Gmail mixed fixture: PDF and named text attachment, not the alternative body",
               MailAttachmentList.from(structure: mixed).map(\.filename) == ["informe.pdf", "notas.txt"]
                   && withoutSize(MailAttachmentList.from(message: fixtureMixed)) == withoutSize(MailAttachmentList.from(structure: mixed)))
    }
    if let alternative = parsedStructure(fixtureAlternativeStructure), let related = parsedStructure(fixtureRelatedStructure) {
        expect("ATT list: plain alternatives and related cid images list nothing",
               MailAttachmentList.from(structure: alternative).isEmpty && MailAttachmentList.from(structure: related).isEmpty
                   && MailAttachmentList.from(message: fixtureRelated).isEmpty && MailAttachmentList.from(message: fixtureAlternative).isEmpty)
    }
    let pdfOnly = crlfData("Content-Type: application/pdf; name=\"solo.pdf\"\nContent-Transfer-Encoding: base64\n\nJVBERi0xLjQK")
    expect("ATT list: a message that is a single PDF part lists it as section 1",
           MailAttachmentList.from(message: pdfOnly).map(\.section) == ["1"] && MailAttachmentList.from(message: pdfOnly).first?.filename == "solo.pdf"
               && parsedStructure(#"("APPLICATION" "PDF" ("NAME" "solo.pdf") NIL NIL "BASE64" 12 NIL NIL NIL NIL)"#)
                   .map { MailAttachmentList.from(structure: $0).map(\.section) } == ["1"])
    let attachedImage = parsedStructure(#"(("TEXT" "HTML" NIL NIL NIL "7BIT" 9 1)("IMAGE" "JPEG" ("NAME" "foto.jpg") "<f@x>" NIL "BASE64" 9 NIL ("ATTACHMENT" ("FILENAME" "foto.jpg")) NIL) "RELATED" ("BOUNDARY" "b") NIL NIL)"#)
    expect("ATT list: a related image the sender marked as an attachment is listed",
           attachedImage.map { MailAttachmentList.from(structure: $0).map(\.filename) } == ["foto.jpg"])
    expect("ATT list: garbage or a truncated message lists nothing and does not crash",
           MailAttachmentList.from(message: Data([0xff, 0xfe, 0x00])).count <= 1
               && MailAttachmentList.from(message: crlfData("Content-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: app")).count <= 1)

    // Transfer decoding.
    let pdf = Data("%PDF-1.4\n".utf8)
    expect("ATT decode base64 (also wrapped and upper-case encoding name)",
           MailAttachment.decode(Data("JVBERi0xLjQK".utf8), encoding: "base64") == pdf
               && MailAttachment.decode(Data("JVBE\r\nRi0x\r\nLjQK".utf8), encoding: "BASE64") == pdf)
    expect("ATT decode quoted-printable with soft line breaks",
           MailAttachment.decode(Data("Caf=C3=A9 =\r\ncon leche".utf8), encoding: "quoted-printable") == Data("Café con leche".utf8))
    expect("ATT decode 7bit / 8bit / nil returns the bytes unchanged",
           [nil, "7bit", "8bit", "binary"].allSatisfy { MailAttachment.decode(Data([0, 1, 0xff]), encoding: $0) == Data([0, 1, 0xff]) })
    let malformed: [(String, String)] = [("base64", "@@@!!=="), ("base64", "A"), ("base64", "===="), ("quoted-printable", "=G1=Z"),
                                         ("quoted-printable", "trailing="), ("x-unknown", "abc")]
    for (encoding, text) in malformed {
        _ = MailAttachment.decode(Data(text.utf8), encoding: encoding)
    }
    expect("ATT decode survives malformed base64 and quoted-printable without crashing", true)
    let big = MailAttachment(section: "2", filename: "x", mime: "application/zip", size: 70 * 1024 * 1024, encoding: "base64")
    let fits = MailAttachment(section: "2", filename: "x", mime: "application/zip", size: 60 * 1024 * 1024, encoding: "base64")
    expect("ATT size: a base64 part is judged by its decoded size against the 50 MB limit", big.isTooLarge && !fits.isTooLarge)
}

// MARK: (1) Attachments: file names and saving

func checkAttachmentFiles() throws {
    typealias F = MailAttachmentFiles
    func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && !name.hasPrefix(".") && name != "." && name != ".."
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
    }
    let hostile = ["../../etc/passwd", "/etc/passwd", "..", ".", "...hidden.pdf", ".bashrc", "a/../../b.txt", "C:\\Windows\\x.exe",
                   "invoice\u{202E}fdp.exe", "a\u{200F}b\u{200E}c\u{2066}d\u{2069}e\u{061C}f.pdf", "a\0b.pdf", "", "   ",
                   "\u{202E}", "\n\r\t", "~/x", "name:with:colons.txt"]
    for name in hostile {
        expect("ATT sanitize \(name.debugDescription) gives a safe single file name", isSafe(F.sanitize(name)))
    }
    expect("ATT sanitize keeps an ordinary name as is", F.sanitize(presupuestoName) == presupuestoName && F.sanitize("café menú.txt") == "café menú.txt")
    expect("ATT sanitize: the RTL override cannot disguise an .exe as a .pdf",
           !F.sanitize("invoice\u{202E}fdp.exe").unicodeScalars.contains("\u{202E}") && F.sanitize("invoice\u{202E}fdp.exe").hasSuffix("exe"))
    // macOS limits a file name to 255 UTF-16 units of its decomposed form (é is e + U+0301): the oracle is that
    // the sanitized name can actually be created.
    let longNames: [(String, String)] = [("300 accented letters", String(repeating: "é", count: 300) + ".pdf"),
                                         ("150 kana with dakuten", String(repeating: "が", count: 150) + ".pdf"),
                                         ("120 emoji", String(repeating: "📄", count: 120) + ".pdf"),
                                         ("400 ASCII letters", String(repeating: "a", count: 400) + ".pdf"),
                                         ("200 CJK characters", String(repeating: "日本", count: 100))]
    expect("ATT sanitize keeps the extension of a long name",
           F.sanitize(String(repeating: "a", count: 400) + ".pdf").hasSuffix(".pdf")
               && F.sanitize(String(repeating: "é", count: 300) + ".pdf").hasSuffix(".pdf"))

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cala-att-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: directory.appendingPathComponent("a.pdf"))
    try Data("second".utf8).write(to: directory.appendingPathComponent("a 2.pdf"))
    try Data("readme".utf8).write(to: directory.appendingPathComponent("README"))
    expect("ATT uniqueURL picks the next free numbered name and never an existing file",
           F.uniqueURL(for: "a.pdf", in: directory).lastPathComponent == "a 3.pdf"
               && F.uniqueURL(for: "README", in: directory).lastPathComponent == "README 2"
               && F.uniqueURL(for: "new.pdf", in: directory).lastPathComponent == "new.pdf")
    expect("ATT uniqueURL stays inside the directory for hostile names",
           hostile.allSatisfy { F.uniqueURL(for: $0, in: directory).deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path })

    let saved = try F.save(Data("payload".utf8), named: "a.pdf", in: directory)
    expect("ATT save never replaces an existing file", saved.lastPathComponent == "a 3.pdf"
               && (try? Data(contentsOf: directory.appendingPathComponent("a.pdf"))) == Data("first".utf8)
               && (try? Data(contentsOf: saved)) == Data("payload".utf8))
    var buffer = [CChar](repeating: 0, count: 256)
    let length = getxattr(saved.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    let quarantine = length > 0 ? String(cString: buffer) : ""
    expect("ATT save sets com.apple.quarantine (0083;<hex time>;Cala;<uuid>)",
           quarantine.hasPrefix("0083;") && quarantine.split(separator: ";").count == 4 && quarantine.contains(";Cala;"))
    let mode = ((try? FileManager.default.attributesOfItem(atPath: saved.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect("ATT saved files are not executable", mode & 0o111 == 0)
    // A symlink planted under the name: the write must not follow it.
    let outside = directory.appendingPathComponent("outside.txt")
    try Data("untouched".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.pdf"), withDestinationURL: outside)
    let besideLink = try F.save(Data("new".utf8), named: "link.pdf", in: directory)
    expect("ATT save does not write through a symlink that has the chosen name",
           (try? Data(contentsOf: outside)) == Data("untouched".utf8) && besideLink.lastPathComponent != "link.pdf")
    let hostileSaved = try F.save(Data("x".utf8), named: "../../escape.txt", in: directory)
    expect("ATT save of a path-traversal name lands inside the directory",
           hostileSaved.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
               && !FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
    for (label, name) in longNames {
        let safe = F.sanitize(name)
        var longSaved: URL?
        do { longSaved = try F.save(Data("x".utf8), named: name, in: directory) } catch {}
        expect("ATT save of a very long name (\(label), \(name.utf8.count) bytes) succeeds: the sanitized name fits the file system (\(safe.decomposedStringWithCanonicalMapping.utf16.count) UTF-16 units decomposed)",
               longSaved.map { FileManager.default.fileExists(atPath: $0.path) } == true && isSafe(safe))
    }
}

// MARK: (1) Attachments over the wire (.fast)

func checkAttachmentWire() async throws {
    let account = "unit@gmail.com"
    let world = FakeIMAPWorld(uids: [(1, false)])
    world.mutate {
        $0.messages.append(.init(uid: 9, unread: true, raw: fixtureAttachments, structure: fixtureAttachmentsStructure))
        $0.messages.append(.init(uid: 10, unread: true, raw: fixtureMixed, structure: fixtureMixedStructure))
    }
    let imap = MailIMAP(socket: world.connect(), provider: .gmail, tuning: .fast)
    try await imap.open(email: account, password: "pw")
    let inbox = try await imap.synchronize(accountID: account)
    guard let row = inbox.messages.first(where: { $0.uid == 9 }), let mixedRow = inbox.messages.first(where: { $0.uid == 10 }) else {
        expect("ATT wire rows", false); return
    }
    var start = world.log.count
    let mixedOpened = try await imap.contentWithAttachments(of: mixedRow)
    expect("ATT wire: opening a message with attachments lists them without downloading any attachment part",
           mixedOpened.attachments.map(\.filename) == ["informe.pdf", "notas.txt"]
               && !world.commands[start...].contains { peekedSectionsOf($0).contains { $0 == "2" || $0 == "3" } || $0.contains("BODY.PEEK[]") })
    start = world.log.count
    let opened = try await imap.contentWithAttachments(of: row)
    expect("ATT wire: a message with a forwarded message/rfc822 is read whole, and its list is still the right one",
           world.commands[start...].last == "UID FETCH 9 (UID BODY.PEEK[])" && opened.attachments.map(\.section) == ["2", "3", "4", "5", "6"]
               && opened.attachments.first?.filename == presupuestoName)
    let parts = Dictionary(uniqueKeysWithValues: opened.attachments.map { ($0.section, $0) })
    start = world.log.count
    let pdf = try await imap.attachmentData(of: row, part: parts["2"]!)
    expect("ATT wire: a download is exactly UID FETCH n (UID BODY.PEEK[section]) and returns the decoded bytes",
           Array(world.commands[start...]) == ["UID FETCH 9 (UID BODY.PEEK[2])"] && pdf == Data("%PDF-1.4\n".utf8))
    let text = try await imap.attachmentData(of: row, part: parts["3"]!)
    let binary = try await imap.attachmentData(of: row, part: parts["4"]!)
    expect("ATT wire: quoted-printable and 7bit parts are decoded / passed through",
           text == Data("Café con leche".utf8) && binary == Data("AAAA".utf8))
    expect("ATT wire: downloads never write flags or move anything",
           !world.commands.contains { $0.contains("STORE") || $0.contains("MOVE") || $0.contains("EXPUNGE") || $0.contains("COPY") })

    // Cancel while the server is still sending: the connection stays usable and the late reply is ignored.
    world.on("UID FETCH 9 (UID BODY.PEEK[2])", .hold)
    let flag = MailCancelFlag()
    let download = Task { () -> Error? in
        do { _ = try await imap.attachmentData(of: row, part: parts["2"]!, shouldCancel: { flag.isCancelled }); return nil } catch { return error }
    }
    _ = await waitFor { world.heldCount == 1 }
    let cancelledAt = ContinuousClock.now
    flag.cancel()
    let cancelError = await download.value
    expect("ATT wire: cancelling a running download ends it within ~1 s with an error",
           cancelError != nil && cancelledAt.duration(to: .now) < .milliseconds(1_500))
    world.release()   // the late answer arrives while the next command runs
    start = world.log.count
    let after = try await imap.synchronize(accountID: account)
    expect("ATT wire: after a cancelled download the same connection syncs correctly (late reply skipped)",
           after.messages.map(\.uid).sorted() == [1, 9, 10] && world.connectionCount == 1)
    expect("ATT wire: cancelling sent nothing destructive",
           !world.commands[start...].contains { $0.contains("STORE") || $0.contains("MOVE") || $0.contains("EXPUNGE") }
               && !world.commands.contains { $0.hasPrefix("UID STORE") })

    // A server that sends far more than the part's declared size, beyond the download limit.
    let declared = MailAttachment(section: "4", filename: "x.bin", mime: "application/octet-stream", size: 4, encoding: nil)
    let hugeCount = MailAttachment.downloadLimit + 1
    world.on("UID FETCH 9 (UID BODY.PEEK[4])", .reply("* 2 FETCH (UID 9 BODY[4] {\(hugeCount)}\r\n" + String(repeating: "A", count: hugeCount) + ")\r\n§ OK done"))
    var hugeError: Error?
    do { _ = try await imap.attachmentData(of: row, part: declared) } catch { hugeError = error }
    expect("ATT wire: a literal larger than the download limit is refused",
           { if case MailIMAPError.messageTooLarge? = hugeError { return true }; return false }())
    start = world.log.count
    let tooBig = MailAttachment(section: "2", filename: "x", mime: "application/zip", size: 80 * 1024 * 1024, encoding: "base64")
    var tooBigError: Error?
    do { _ = try await imap.attachmentData(of: row, part: tooBig) } catch { tooBigError = error }
    expect("ATT wire: a part declared over the limit is refused before anything is sent",
           { if case MailIMAPError.messageTooLarge? = tooBigError { return true }; return false }() && world.log.count == start)
    var stale = row
    stale.uidValidity = 6
    do { _ = try await imap.attachmentData(of: stale, part: parts["2"]!); expect("ATT wire: stale epoch refused", false) } catch {
        expect("ATT wire: an attachment of another UIDVALIDITY epoch is refused before anything is sent", world.log.count == start)
    }
}

private func peekedSectionsOf(_ command: String) -> [String] {
    var result: [String] = []
    var rest = Substring(command)
    while let range = rest.range(of: "BODY.PEEK[") {
        rest = rest[range.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { break }
        result.append(String(rest[..<close]))
        rest = rest[rest.index(after: close)...]
    }
    return result
}

@MainActor
func checkAttachmentService() async throws {
    let world = FakeIMAPWorld(uids: [(1, false)])
    world.mutate { $0.messages.append(.init(uid: 9, unread: false, raw: fixtureAttachments, structure: fixtureAttachmentsStructure)) }
    let h = try MailHarness(world: world)
    defer { h.finish() }
    guard await h.start(rows: 2), let row = h.row(9) else { expect("ATT service: harness synced", false); return }
    _ = try await h.service.content(of: row)
    guard let list = h.service.attachments(for: row), let pdf = list.first(where: { $0.section == "2" }),
          let text = list.first(where: { $0.section == "3" }) else { expect("ATT service: attachments listed after opening", false); return }
    expect("ATT service: the reader's list after opening matches the message", list.map(\.section) == ["2", "3", "4", "5", "6"])
    h.service.fetchAttachment(pdf, of: row)
    _ = await waitFor { h.service.attachmentState(row, pdf) == .ready }
    expect("ATT service: a requested download becomes ready with the decoded bytes in memory",
           h.service.attachmentState(row, pdf) == .ready && h.service.attachmentData(row, pdf) == Data("%PDF-1.4\n".utf8))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cala-dl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = h.service.saveAttachment(pdf, of: row, to: directory)
    let second = h.service.saveAttachment(pdf, of: row, to: directory)
    expect("ATT service: saving twice gives two files with the decoded name, the first untouched",
           first?.lastPathComponent == presupuestoName && second != nil && second != first
               && first.flatMap { try? Data(contentsOf: $0) } == Data("%PDF-1.4\n".utf8))
    expect("ATT service: saving an attachment that was not downloaded does nothing", h.service.saveAttachment(text, of: row, to: directory) == nil)

    world.on("UID FETCH 9 (UID BODY.PEEK[3])", .hold)
    h.service.fetchAttachment(text, of: row)
    _ = await waitFor { world.heldCount == 1 }
    h.service.cancelAttachment(text, of: row)
    expect("ATT service: cancel returns the attachment to idle at once", h.service.attachmentState(row, text) == .idle)
    _ = await waitFor(2) { false }
    world.release()
    h.service.refresh()
    _ = await h.settle()
    expect("ATT service: a cancelled download leaves no notice, no bytes and a working connection",
           h.service.notices.isEmpty && h.service.attachmentData(row, text) == nil && h.service.attachmentState(row, text) == .idle
               && world.connectionCount == 1 && h.service.messages.count == 2)
    let huge = MailAttachment(section: "6", filename: "big.zip", mime: "application/zip", size: 90 * 1024 * 1024, encoding: "base64")
    let sent = world.log.count
    h.service.fetchAttachment(huge, of: row)
    expect("ATT service: an attachment over 50 MB fails at once with a notice and sends nothing",
           h.service.attachmentState(row, huge) == .failed && h.service.notices.count == 1 && world.log.count == sent)
}

// MARK: (2) Bulk actions on selected rows

@MainActor
func checkBulkActions() async throws {
    let base: [(UInt32, Bool)] = [(1, false), (2, true), (3, true), (4, true), (5, false)]
    func moves(_ world: FakeIMAPWorld) -> [String] { world.commands.filter { $0.hasPrefix("UID MOVE") || $0.hasPrefix("UID COPY") } }

    // MOVE path, one publish, one command for the whole set.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 5) else { expect("BULK harness synced", false); return }
        let selected = h.service.messages.filter { [1, 2, 3, 5].contains($0.uid) }
        h.record()
        h.service.trash(selected)
        expect("BULK delete: every selected row leaves the list in the same (first) publish",
               h.published.count == 1 && h.published.first?.map(\.uid) == [4] && h.service.unreadCount == 1)
        _ = await h.settle { world.count("UID MOVE") == 1 && h.service.messages.count == 1 }
        expect("BULK delete (.fast, MOVE): one UID MOVE with the compact UID set", moves(world) == [#"UID MOVE 1:3,5 "[Gmail]/Trash""#])
        expect("BULK delete: wire-safe, no EXPUNGE, no notice, no flicker",
               wireIsSafe(world.log.map { ($0.command, $0.status) }) && !world.commands.contains { $0.contains("EXPUNGE") }
                   && h.service.notices.isEmpty && h.published.allSatisfy { $0.map(\.uid) == [4] })
    }
    // UIDPLUS fallback.
    do {
        let world = FakeIMAPWorld(uids: base)
        world.mutate { $0.capabilities = "IDLE UIDPLUS" }
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 5) else { expect("BULK UIDPLUS harness synced", false); return }
        h.service.trash(h.service.messages.filter { [1, 2, 3, 5].contains($0.uid) })
        _ = await h.settle { world.count("UID EXPUNGE") == 1 && h.service.messages.count == 1 }
        let mutating = world.commands.filter { $0.hasPrefix("UID COPY") || $0.hasPrefix("UID STORE") || $0.hasPrefix("UID EXPUNGE") || $0 == "EXPUNGE" }
        expect("BULK delete (UIDPLUS): COPY, STORE \\Deleted and UID EXPUNGE of the same set, never a plain EXPUNGE",
               mutating == [#"UID COPY 1:3,5 "[Gmail]/Trash""#, #"UID STORE 1:3,5 +FLAGS.SILENT (\Deleted)"#, "UID EXPUNGE 1:3,5"]
                   && wireIsSafe(world.log.map { ($0.command, $0.status) }))
    }
    // Refused: everything comes back with one notice.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 5) else { expect("BULK NO harness synced", false); return }
        let before = h.service.messages
        world.on("UID MOVE", .reply("§ NO [OVERQUOTA] cannot move"), times: 9)
        h.service.trash(h.service.messages.filter { $0.uid != 4 })
        _ = await h.settle { h.service.notices.count >= 1 }
        _ = await waitFor(0.2) { false }
        expect("BULK delete answered NO: every row returns unchanged and exactly one notice is shown",
               h.service.messages == before && h.service.notices.count == 1 && h.service.unreadCount == 3)
        expect("BULK delete answered NO: no per-message retries", world.count("UID MOVE") == 1)
    }
    // Lost answer: the server moved part of the set before the link dropped.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 5) else { expect("BULK lost harness synced", false); return }
        world.on("UID MOVE", .hold)
        h.record()
        h.service.trash(h.service.messages.filter { [1, 2, 3, 5].contains($0.uid) })
        _ = await waitFor { world.heldCount == 1 }
        world.mutate { $0.messages.removeAll { $0.uid == 1 || $0.uid == 2 } }   // moved before the link died
        world.release(.drop)
        _ = await h.settle { world.connectionCount >= 2 && world.count("UID FETCH 1:3,5 (UID FLAGS)") == 1 && h.service.messages.count == 3 }
        _ = await h.settle()
        expect("BULK lost answer: the set is checked with one UID FETCH set (UID FLAGS) on the new connection",
               world.log.filter { $0.command == "UID FETCH 1:3,5 (UID FLAGS)" }.map(\.connection) == [2])
        expect("BULK lost answer: only the rows still in the inbox come back; moved ones never reappear",
               h.service.messages.map(\.uid) == [5, 4, 3] && h.published.allSatisfy { !$0.contains { $0.uid == 1 || $0.uid == 2 } })
        expect("BULK lost answer: MOVE is never resent and at most one notice is shown",
               world.count("UID MOVE") == 1 && h.service.notices.count <= 1)
    }
    // COPY OK, STORE \Deleted refused on the set.
    do {
        let world = FakeIMAPWorld(uids: base)
        world.mutate { $0.capabilities = "IDLE UIDPLUS" }
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 5) else { expect("BULK half harness synced", false); return }
        let before = h.service.messages
        world.on("UID STORE 1:3 +FLAGS.SILENT (\\Deleted)", .reply("§ NO [CANNOT] store refused"))
        h.service.trash(h.service.messages.filter { [1, 2, 3].contains($0.uid) })
        _ = await h.settle { h.service.notices.count == 1 }
        _ = await waitFor(0.2) { false }
        let notice = h.service.notices.first?.text.lowercased() ?? ""
        expect("BULK COPY OK + STORE NO: no EXPUNGE, the rows are back, one notice saying copies went to the trash",
               world.count("UID EXPUNGE") == 0 && !world.commands.contains("EXPUNGE") && h.service.messages == before
                   && h.service.notices.count == 1 && notice.contains("cop") && (notice.contains("trash") || notice.contains("papelera")))
    }
    // Mark read / unread of a set; mixed accounts.
    do {
        let world = FakeIMAPWorld(uids: base)
        let yahoo = FakeIMAPWorld(uids: [(7, true), (8, true), (9, false)])
        let h = try MailHarness(world: world, second: yahoo)
        defer { h.finish() }
        guard await h.start(rows: 8) else { expect("BULK mixed harness synced", false); return }
        h.service.markRead(h.service.messages)
        expect("BULK mark read: every selected unread row reads as read at once", h.service.unreadCount == 0)
        _ = await h.settle { world.count("UID STORE") == 1 && yahoo.count("UID STORE") == 1 }
        expect("BULK mark read: one STORE per account with only the unread UIDs",
               world.commands.filter { $0.hasPrefix("UID STORE") } == [#"UID STORE 2:4 +FLAGS.SILENT (\Seen)"#]
                   && yahoo.commands.filter { $0.hasPrefix("UID STORE") } == [#"UID STORE 7:8 +FLAGS.SILENT (\Seen)"#])
        let mixed = h.service.messages.filter { [1, 3, 7, 9].contains($0.uid) }
        h.service.trash(mixed)
        expect("BULK mixed-account delete: all selected rows of both accounts leave at once", h.service.messages.map(\.uid).sorted() == [2, 4, 5, 8])
        _ = await h.settle { world.count("UID MOVE") == 1 && yahoo.count("UID MOVE") == 1 }
        expect("BULK mixed-account delete: each account gets one UID MOVE with only its own UIDs",
               moves(world) == [#"UID MOVE 1,3 "[Gmail]/Trash""#] && moves(yahoo) == [#"UID MOVE 7,9 "[Gmail]/Trash""#]
                   && h.service.notices.isEmpty)
        h.service.markUnread(h.service.messages.filter { $0.accountID == MailHarness.account })
        _ = await h.settle { world.count("UID STORE") == 2 }
        expect("BULK mark unread: one -FLAGS \\Seen STORE for the account's read rows",
               world.commands.filter { $0.hasPrefix("UID STORE") }.last == #"UID STORE 2,4:5 -FLAGS.SILENT (\Seen)"#
                   && h.service.messages.filter { $0.accountID == MailHarness.account }.allSatisfy(\.unread))
    }
}

// MARK: (3) Older pages

func checkOlderPager() {
    let all = Array(UInt32(1)...40)
    let first = MailOlderPager.page(candidates: all.shuffled(), below: 16, size: 5)
    expect("OLDER pager: the highest UIDs below the window, newest first, the rest kept for later",
           first.page == [15, 14, 13, 12, 11] && first.rest == Array((1...10).reversed()))
    expect("OLDER pager: `above` bounds the range and duplicates count once",
           MailOlderPager.page(candidates: [3, 3, 5, 9, 12], below: 12, above: 3, size: 10) == ([9, 5], []))
    expect("OLDER pager: empty and degenerate requests",
           MailOlderPager.page(candidates: [], below: 10, size: 5) == ([], [])
               && MailOlderPager.page(candidates: [1, 2], below: 1, size: 5) == ([], [])
               && MailOlderPager.page(candidates: [1, 2], below: 3, size: 0) == ([], [2, 1]))
}

@MainActor
func checkOlderPages() async throws {
    let unreadOlder: Set<UInt32> = [3, 7]
    var rows: [(UInt32, Bool)] = []
    for uid in UInt32(1)...40 { rows.append((uid, uid > 15 ? uid % 2 == 0 : unreadOlder.contains(uid))) }
    let world = FakeIMAPWorld(uids: rows)
    let h = try MailHarness(world: world)
    defer { h.finish() }
    guard await h.start(rows: 25) else { expect("OLDER harness synced", false); return }
    expect("OLDER before loading: the list shows the newest 25 and more can be loaded",
           h.service.messages.map(\.uid).min() == 16 && h.service.canLoadOlder(accountID: nil))
    let start = world.log.count
    h.service.loadOlder(accountID: nil)
    _ = await h.settle { h.service.messages.count == 40 && h.service.olderLoading.isEmpty }
    let sent = Array(world.commands[start...])
    let fetches = sent.filter { $0.hasPrefix("UID FETCH") }
    expect("OLDER load: only UIDs below the window are asked for", fetches.count == 1 && fetches.first?.hasPrefix("UID FETCH 1:15 (") == true
               && sent.filter { $0.hasPrefix("UID SEARCH") }.allSatisfy { $0 == "UID SEARCH UID 1:15" })
    expect("OLDER load: headers and a preview only, never bodies, structures or sizes",
           fetches.allSatisfy { $0.contains("HEADER.FIELDS") && !$0.contains("BODY.PEEK[]") && !$0.contains("BODYSTRUCTURE") && !$0.contains("RFC822.SIZE") }
               && !sent.contains { $0.contains("STORE") })
    let older = h.service.messages.filter { $0.uid < 16 }
    expect("OLDER load: the rows' read state comes from their FLAGS", older.count == 15
               && Set(older.filter(\.unread).map(\.uid)) == unreadOlder && older.first { $0.uid == 1 }?.subject == "Subject 1")
    expect("OLDER load: all older mail was loaded, so no more pages are offered", !h.service.canLoadOlder(accountID: nil))

    // Optimistic delete of an older row: refused first, then accepted.
    guard let five = h.row(5), let six = h.row(6) else { expect("OLDER rows", false); return }
    world.on("UID MOVE 5 ", .reply("§ NO [OVERQUOTA] no"), times: 9)
    h.service.trash(five)
    expect("OLDER delete: an older row leaves the list at once", !h.shows(5))
    _ = await h.settle { h.service.notices.count == 1 }
    expect("OLDER delete answered NO: the older row comes back unchanged with one notice", h.row(5) == five && h.service.notices.count == 1)
    h.service.trash(six)
    _ = await h.settle { world.count("UID MOVE 6 ") == 1 }
    h.service.refresh()
    _ = await waitFor(0.3) { false }
    _ = await h.settle()
    expect("OLDER delete accepted: one UID MOVE for that UID and the row stays gone after later syncs",
           !h.shows(6) && h.service.messages.count == 39 && world.count("UID MOVE 6 ") == 1)

    // A new UIDVALIDITY drops the older pages (their UIDs name other messages now).
    world.on("DONE", .drop)
    world.mutate { $0.validity = 8 }
    h.service.refresh()
    _ = await h.settle { world.connectionCount >= 2 && h.service.messages.allSatisfy { $0.uidValidity == 8 } && h.service.messages.count == 25 }
    expect("OLDER after a UIDVALIDITY change: older pages are cleared, only the new epoch's window is listed, more can be loaded",
           h.service.messages.count == 25 && h.service.messages.allSatisfy { $0.id.contains("#8#") } && h.service.canLoadOlder(accountID: nil))
}

// MARK: Review of df6e985 (F-I2, F-I3, F-I4, F-I7, F-I8, F-I10, F-M6): ordinary checks, expected to fail until fixed.

@MainActor
private func refreshAndSettle(_ h: MailHarness) async {
    h.service.refresh()
    _ = await waitFor(0.3) { false }
    _ = await h.settle()
    _ = await waitFor(0.2) { false }
    _ = await h.settle()
}

@MainActor
private func olderHarness() async throws -> (MailHarness, FakeIMAPWorld)? {
    var rows: [(UInt32, Bool)] = []
    for uid in UInt32(1)...40 { rows.append((uid, false)) }
    let world = FakeIMAPWorld(uids: rows)
    let h = try MailHarness(world: world)
    guard await h.start(rows: 25) else { h.finish(); return nil }
    h.service.loadOlder(accountID: nil)
    guard await h.settle(5, { h.service.messages.count == 40 && h.service.olderLoading.isEmpty }) else { h.finish(); return nil }
    return (h, world)
}

@MainActor
func checkFeatureReviewFindings() async throws {
    func serverUIDs(_ world: FakeIMAPWorld) -> [UInt32] { world.locked { world.messages.map(\.uid) }.sorted(by: >) }
    func shownUIDs(_ h: MailHarness) -> [UInt32] { h.service.messages.map(\.uid).sorted(by: >) }

    // F-I2 (a): the window moves down over loaded older rows, one of them is deleted elsewhere, then the window moves up.
    if let (h, world) = try await olderHarness() {
        defer { h.finish() }
        world.mutate { $0.messages.removeAll { $0.uid > 35 } }                 // the newest five deleted elsewhere
        await refreshAndSettle(h)
        world.mutate { $0.messages.removeAll { $0.uid == 13 } }                // an older row deleted elsewhere
        await refreshAndSettle(h)
        let afterDelete = shownUIDs(h)
        world.mutate { for uid in UInt32(41)...45 { $0.messages.append(.init(uid: uid, unread: true, raw: FakeIMAPWorld.simpleRaw(uid), structure: nil)) } }
        await refreshAndSettle(h)
        expect("F-I2 older pages: rows the window covered are dropped on sync, so a row deleted elsewhere does not come back when the window moves up",
               !afterDelete.contains(13) && !h.shows(13) && shownUIDs(h) == serverUIDs(world))
    } else { expect("F-I2 (a) harness", false) }

    // F-I2 (b): new mail opens a gap between the window and the older pages; the first gap fill fails.
    if let (h, world) = try await olderHarness() {
        defer { h.finish() }
        world.on("UID SEARCH UID 16:", .reply("§ NO [UNAVAILABLE] try later"))
        world.on("UID FETCH 16:", .reply("§ NO [UNAVAILABLE] try later"))
        world.mutate { for uid in UInt32(41)...50 { $0.messages.append(.init(uid: uid, unread: false, raw: FakeIMAPWorld.simpleRaw(uid), structure: nil)) } }
        await refreshAndSettle(h)
        await refreshAndSettle(h)
        await refreshAndSettle(h)
        expect("F-I2 older pages: a gap fill that failed is retried, so no rows stay missing between the window and older pages",
               shownUIDs(h) == serverUIDs(world) && h.service.messages.count == 50)
    } else { expect("F-I2 (b) harness", false) }

    // F-I2 (c): an older row trashed in another client.
    if let (h, world) = try await olderHarness() {
        defer { h.finish() }
        world.mutate { $0.messages.removeAll { $0.uid == 5 } }
        await refreshAndSettle(h)
        expect("F-I2 older pages: a message trashed elsewhere disappears from the older pages after the FLAGS refresh",
               !h.shows(5) && shownUIDs(h) == serverUIDs(world))
    } else { expect("F-I2 (c) harness", false) }

    // F-I3: a NO to a bulk UID MOVE after the server moved part of the set.
    do {
        let world = FakeIMAPWorld(uids: [(1, false), (2, true), (3, true), (4, true), (5, false)])
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 5) else { expect("F-I3 harness", false); return }
        world.on("UID MOVE", .hold)
        h.record()
        h.service.trash(h.service.messages.filter { [1, 2, 3, 5].contains($0.uid) })
        _ = await waitFor { world.heldCount == 1 }
        world.mutate { $0.messages.removeAll { $0.uid == 1 || $0.uid == 2 } }  // partly done, then refused
        world.release(.reply("§ NO [OVERQUOTA] partly moved"))
        _ = await h.settle { h.service.notices.count >= 1 }
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        expect("F-I3 bulk MOVE answered NO: the set is verified per UID with UID FETCH set (UID FLAGS)",
               world.commands.contains("UID FETCH 1:3,5 (UID FLAGS)"))
        expect("F-I3 bulk MOVE answered NO: rows the server did move stay hidden, the others come back, MOVE never resent",
               shownUIDs(h) == [5, 4, 3] && h.published.allSatisfy { !$0.contains { $0.uid == 1 || $0.uid == 2 } }
                   && world.count("UID MOVE") == 1)
    }

    // F-I4 and F-I10: downloads after a cancel.
    do {
        let world = FakeIMAPWorld(uids: [(1, false)])
        world.mutate { $0.messages.append(.init(uid: 9, unread: false, raw: fixtureAttachments, structure: fixtureAttachmentsStructure)) }
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 2), let row = h.row(9) else { expect("F-I4 harness", false); return }
        _ = try await h.service.content(of: row)
        guard let list = h.service.attachments(for: row), let pdf = list.first(where: { $0.section == "2" }),
              let text = list.first(where: { $0.section == "3" }) else { expect("F-I4 attachments listed", false); return }
        world.on("UID FETCH 9 (UID BODY.PEEK[3])", .hold)
        world.on("UID FETCH 9 (UID BODY.PEEK[2])", .hold)
        h.service.fetchAttachment(text, of: row)
        _ = await waitFor { world.heldCount == 1 }
        h.service.cancelAttachment(text, of: row)
        h.service.fetchAttachment(pdf, of: row)
        _ = await waitFor(3) { world.heldCount == 2 }
        world.release()   // the cancelled part-3 reply arrives first, as a server would send it
        world.release()   // then part 2
        _ = await waitFor(3) { h.service.attachmentState(row, pdf) != .downloading(0) && h.service.attachmentState(row, pdf) != .idle
                               && { if case .downloading = h.service.attachmentState(row, pdf) { return false }; return true }() }
        expect("F-I4 after cancelling an in-flight download, another part of the same message downloads and has its own bytes",
               h.service.attachmentState(row, pdf) == .ready && h.service.attachmentData(row, pdf) == Data("%PDF-1.4\n".utf8)
                   && h.service.attachmentData(row, text) == nil)
    }
    do {
        let world = FakeIMAPWorld(uids: [(1, false)])
        world.mutate { $0.messages.append(.init(uid: 9, unread: false, raw: fixtureAttachments, structure: fixtureAttachmentsStructure)) }
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 2), let row = h.row(9) else { expect("F-I10 harness", false); return }
        _ = try await h.service.content(of: row)
        guard let text = h.service.attachments(for: row)?.first(where: { $0.section == "3" }) else { expect("F-I10 listed", false); return }
        world.on("UID FETCH 9 (UID BODY.PEEK[3])", .hold, times: 2)
        h.service.fetchAttachment(text, of: row)
        _ = await waitFor { world.heldCount == 1 }
        h.service.cancelAttachment(text, of: row)
        h.service.fetchAttachment(text, of: row)                               // the person asks again right away
        _ = await waitFor(1.5) { false }                                       // the cancelled read gives up meanwhile
        let whileSecondRuns = h.service.attachmentState(row, text)
        world.release()
        _ = await waitFor(3) { world.heldCount == 1 || h.service.attachmentState(row, text) == .ready }
        world.release()
        _ = await waitFor(3) { h.service.attachmentState(row, text) == .ready }
        expect("F-I10 cancel then download again: the first (cancelled) download does not reset the second one's state",
               { if case .downloading = whileSecondRuns { return true }; return false }())
        expect("F-I10 cancel then download again: the second download completes with the part's bytes",
               h.service.attachmentState(row, text) == .ready && h.service.attachmentData(row, text) == Data("Café con leche".utf8))
    }

    // F-I7: base64 as some senders write it.
    let eight = Data("%PDF-1.4".utf8)
    expect("F-I7 base64 without padding decodes", MailAttachment.decode(Data("JVBERi0xLjQ".utf8), encoding: "base64") == eight)
    expect("F-I7 base64 with trailing junk after the data decodes the data",
           MailAttachment.decode(Data("JVBERi0xLjQ=\r\n--\r\n".utf8), encoding: "base64") == eight
               && MailAttachment.decode(Data("JVBERi0xLjQK*".utf8), encoding: "base64") == Data("%PDF-1.4\n".utf8))

    // F-I8: file name length in bytes and the remaining invisible separators.
    for (label, name) in [("300 accented letters", String(repeating: "é", count: 300) + ".pdf"),
                          ("150 kana", String(repeating: "が", count: 150) + ".pdf"),
                          ("120 emoji", String(repeating: "📄", count: 120) + ".pdf")] {
        let safe = MailAttachmentFiles.sanitize(name)
        expect("F-I8 sanitize truncates \(label) to at most 255 UTF-8 bytes and keeps .pdf (got \(safe.utf8.count) bytes)",
               safe.utf8.count <= 255 && safe.hasSuffix(".pdf") && !safe.isEmpty)
    }
    let invisible: [Unicode.Scalar] = ["\u{2028}", "\u{2029}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                       "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
    let disguised = "fac" + invisible.map { String($0) }.joined(separator: "x") + "tura.pdf"
    let cleaned = MailAttachmentFiles.sanitize(disguised)
    expect("F-I8 sanitize strips U+2028/U+2029 and the bidi controls U+202A-U+202E, U+2066-U+2069",
           !cleaned.unicodeScalars.contains { invisible.contains($0) } && cleaned.hasSuffix(".pdf"))

    // F-M6: an RFC 2231 name given both whole and in pieces.
    let both = MailAttachmentList.filename(disposition: ["filename*": "utf-8''informe.pdf", "filename*0*": "utf-8''otro%20", "filename*1": "nombre.txt"],
                                           contentType: [:])
    expect("F-M6 filename* and filename*0* are not merged into one name (got \(both.debugDescription))",
           both == "informe.pdf" || both == "otro nombre.txt")
}

// MARK: Review of 77dc3f0 (G-1 ... G-5): ordinary checks, failing until fixed.

@MainActor
private func manyRows(_ uids: [UInt32]) -> FakeIMAPWorld { FakeIMAPWorld(uids: uids.map { ($0, false) }) }

@MainActor
func checkGFindings() async throws {
    func shownUIDs(_ h: MailHarness) -> [UInt32] { h.service.messages.map(\.uid).sorted(by: >) }
    func serverUIDs(_ world: FakeIMAPWorld) -> [UInt32] { world.locked { world.messages.map(\.uid) }.sorted(by: >) }
    func refreshAndSettle(_ h: MailHarness) async {
        h.service.refresh()
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        _ = await waitFor(0.2) { false }
        _ = await h.settle()
    }

    // G-1: a page of older rows lands while the FLAGS refresh of the earlier older rows is still unanswered.
    do {
        let world = manyRows(Array(1...60))
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 25) else { expect("G-1 harness", false); return }
        h.service.loadOlder(accountID: nil)
        _ = await h.settle { h.service.messages.count == 50 && h.service.olderLoading.isEmpty }
        world.on("UID FETCH 1:10 (UID FLAGS INTERNALDATE", .hold)
        world.on("UID FETCH 11:35 (UID FLAGS)", .hold)
        h.service.loadOlder(accountID: nil)                     // page 2 (UIDs 1-10): its answer is held
        _ = await waitFor { world.heldCount == 1 }
        h.service.refresh()                                     // panel opens: FLAGS refresh of rows 11-35 is queued
        world.release()                                         // page 2 arrives first
        _ = await waitFor(3) { world.heldCount == 1 && h.service.messages.count == 60 }
        world.release()                                         // then the FLAGS answer, which knows nothing of page 2
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        expect("G-1 an older page loaded while a FLAGS refresh was pending is still shown after the refresh answer",
               shownUIDs(h) == serverUIDs(world) && h.service.messages.count == 60)
    }

    // G-2: a gap fill whose second page fails.
    do {
        let world = manyRows(Array(1...40))
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 25) else { expect("G-2 harness", false); return }
        h.service.loadOlder(accountID: nil)
        _ = await h.settle { h.service.messages.count == 40 && h.service.olderLoading.isEmpty }
        world.on("UID FETCH 16:25 (UID FLAGS INTERNALDATE", .reply("§ NO [UNAVAILABLE] try later"))
        world.mutate { for uid in UInt32(41)...75 { $0.messages.append(.init(uid: uid, unread: false, raw: FakeIMAPWorld.simpleRaw(uid), structure: nil)) } }
        await refreshAndSettle(h)                               // window 51-75; gap 16-50: page 26-50 OK, page 16-25 refused
        let shown = Set(shownUIDs(h))
        let window = Set(UInt32(51)...75), first = Set(UInt32(1)...15)
        expect("G-2 a gap fill whose second page fails adds nothing (no hole below the added rows)",
               shown == window.union(first) || shown == Set(serverUIDs(world)))
        await refreshAndSettle(h)
        await refreshAndSettle(h)
        expect("G-2 after a later successful fill, every UID between the older pages and the window is listed",
               shownUIDs(h) == serverUIDs(world))
    }

    // G-3: UIDs 16-20 never existed; the "gap" is permanent and must not be searched every sync.
    do {
        let world = manyRows(Array(1...15) + Array(21...45))
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 25) else { expect("G-3 harness", false); return }
        h.service.loadOlder(accountID: nil)
        _ = await h.settle { h.service.messages.count == 40 && h.service.olderLoading.isEmpty }
        let before = world.commands.filter { $0.hasPrefix("UID SEARCH UID ") }.count
        for _ in 0..<4 { await refreshAndSettle(h) }
        let searches = world.commands.filter { $0.hasPrefix("UID SEARCH UID ") }.count - before
        expect("G-3 four syncs without window movement over a non-contiguous UID gap send at most one gap UID SEARCH (sent \(searches))",
               searches <= 1 && shownUIDs(h) == serverUIDs(world))
    }

    // G-4: the 500-row cap on older pages.
    do {
        let world = manyRows(Array(1...600))
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 25) else { expect("G-4 harness", false); return }
        var pages = 0
        while h.service.messages.count < 25 + MailService.olderLimit && pages < 25 && h.service.canLoadOlder(accountID: nil) {
            let count = h.service.messages.count
            h.service.loadOlder(accountID: nil)
            _ = await h.settle { h.service.messages.count > count && h.service.olderLoading.isEmpty }
            pages += 1
        }
        expect("G-4 older pages fill up to the 500-row cap", h.service.messages.count == 25 + MailService.olderLimit)
        let sent = world.log.count
        h.service.loadOlder(accountID: nil)
        _ = await waitFor(0.5) { false }
        _ = await h.settle()
        expect("G-4 at the 500-row cap, load older sends no further fetch and reports exhausted",
               !world.commands[sent...].contains { $0.hasPrefix("UID FETCH") || $0.hasPrefix("UID SEARCH UID") }
                   && !h.service.canLoadOlder(accountID: nil) && h.service.messages.count == 25 + MailService.olderLimit)
    }

    // G-5: chunked downloads (parts over MailIMAP.attachmentChunk).
    func chunkWorld(bodyCount: Int) -> (FakeIMAPWorld, Data) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var body = [UInt8](repeating: 0, count: bodyCount)
        for index in body.indices { body[index] = alphabet[(index * 7 + index / 1000) % alphabet.count] }
        let raw = crlfData("Content-Type: multipart/mixed; boundary=\"c\"\n\n--c\nContent-Type: text/plain\n\nHola\n--c\nContent-Type: application/octet-stream\nContent-Disposition: attachment; filename=\"big.bin\"\n\n")
            + Data(body) + crlfData("\n--c--\n")
        let structure = #"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 4 1 NIL NIL NIL NIL)("APPLICATION" "OCTET-STREAM" NIL NIL NIL "7BIT" \#(bodyCount) NIL ("ATTACHMENT" ("FILENAME" "big.bin")) NIL NIL) "MIXED" ("BOUNDARY" "c") NIL NIL NIL)"#
        let world = FakeIMAPWorld(uids: [(1, false)])
        world.mutate { $0.messages.append(.init(uid: 9, unread: false, raw: raw, structure: structure)) }
        return (world, Data(body))
    }
    func download(_ world: FakeIMAPWorld) async throws -> (MailHarness, MailMessage, MailAttachment)? {
        let h = try MailHarness(world: world)
        guard await h.start(rows: 2), let row = h.row(9) else { h.finish(); return nil }
        _ = try await h.service.content(of: row)
        guard let part = h.service.attachments(for: row)?.first(where: { $0.section == "2" }) else { h.finish(); return nil }
        h.service.fetchAttachment(part, of: row)
        _ = await waitFor(10) {
            let state = h.service.attachmentState(row, part)
            return state == .ready || state == .failed
        }
        return (h, row, part)
    }
    do {
        let chunk = MailIMAP.attachmentChunk
        let (world, body) = chunkWorld(bodyCount: 2 * chunk)
        if let (h, row, part) = try await download(world) {
            defer { h.finish() }
            let chunks = world.commands.filter { $0.hasPrefix("UID FETCH 9 (UID BODY.PEEK[2]<") }
            expect("G-5 a part ending exactly on a chunk boundary downloads in 1 MB chunks and is byte-exact",
                   h.service.attachmentState(row, part) == .ready && h.service.attachmentData(row, part) == body
                       && chunks.first == "UID FETCH 9 (UID BODY.PEEK[2]<0.\(chunk)>)"
                       && chunks.dropFirst().first == "UID FETCH 9 (UID BODY.PEEK[2]<\(chunk).\(chunk)>)")
        } else { expect("G-5 boundary harness", false) }
    }
    do {
        let chunk = MailIMAP.attachmentChunk
        let (world, _) = chunkWorld(bodyCount: chunk * 5 / 2)
        world.on("UID FETCH 9 (UID BODY.PEEK[2]<\(chunk).\(chunk)>)",
                 .reply("* 2 FETCH (UID 9 BODY[2]<\(chunk)> {1000}\r\n" + String(repeating: "x", count: 1000) + ")\r\n§ OK done"))
        if let (h, row, part) = try await download(world) {
            defer { h.finish() }
            expect("G-5 a short non-final chunk fails the download instead of producing a truncated file",
                   h.service.attachmentState(row, part) == .failed && h.service.attachmentData(row, part) == nil)
        } else { expect("G-5 short-chunk harness", false) }
    }
}

// MARK: Entry point

@MainActor
func runFeatureChecks() async {
    checkAttachmentLists()
    do { try checkAttachmentFiles() } catch { expect("Attachment file checks ran (\(error))", false) }
    checkOlderPager()
    do { try await checkAttachmentWire() } catch { expect("Attachment wire checks ran (\(error))", false) }
    do { try await checkAttachmentService() } catch { expect("Attachment service checks ran (\(error))", false) }
    do { try await checkBulkActions() } catch { expect("Bulk action checks ran (\(error))", false) }
    do { try await checkOlderPages() } catch { expect("Older page checks ran (\(error))", false) }
    do { try await checkFeatureReviewFindings() } catch { expect("df6e985 review checks ran (\(error))", false) }
    do { try await checkGFindings() } catch { expect("77dc3f0 review checks ran (\(error))", false) }
}
