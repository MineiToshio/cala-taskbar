import Foundation

/// The app writes this to its debug log; the checks have no log file.
func log(_ s: String) {}

var passes = 0
var failures = 0
/// Appended to every check name while a block of checks is re-run under another configuration (e.g. " [.fast]").
var checkSuffix = ""
/// Debug aid (MAIL_DEBUG=1): called with the name of each failing check.
var failureHook: ((String) -> Void)?

func expect(_ name: String, _ condition: Bool) {
    if condition {
        passes += 1
        print("PASS \(name)\(checkSuffix)")
    } else {
        failures += 1
        print("FAIL \(name)\(checkSuffix)")
        failureHook?(name)
    }
}

func wire(_ text: String) -> Data { Data(text.utf8) }
func crlf(_ text: String) -> Data { wire(text.replacingOccurrences(of: "\n", with: "\r\n")) }

let emoji = wire("Confirmación 📬").base64EncodedString()
expect("RFC 2047 UTF-8 B and emoji", MailMIME.decodeHeader("=?UTF-8?B?\(emoji)?=") == "Confirmación 📬")
expect("RFC 2047 ISO-8859-1 Q", MailMIME.decodeHeader("=?iso-8859-1?q?Reuni=F3n_en_ma=F1ana?=") == "Reunión en mañana")
expect("RFC 2047 Windows-1252 Q", MailMIME.decodeHeader("=?Windows-1252?Q?=93S=ED=94_=96_=80?=") == "“Sí” – €")
expect("Adjacent encoded words across folded whitespace",
       MailMIME.decodeHeader("=?UTF-8?Q?Hola,_?=\r\n\t=?UTF-8?Q?Jos=C3=A9?=") == "Hola, José")
expect("Whitespace next to ordinary words", MailMIME.decodeHeader("Re: =?UTF-8?Q?D=C3=ADa?= libre") == "Re: Día libre")
expect("Invalid B word remains readable", MailMIME.decodeHeader("=?UTF-8?B?#?= literal") == "=?UTF-8?B?#?= literal")
expect("Unencoded subject survives", MailMIME.decodeHeader("Información ☀️") == "Información ☀️")
expect("Header unfolding and case-insensitive names",
       MailMIME.headers(wire("SuBJect: Hola\r\n\tJosé\r\nFROM: a@example.test\r\n\r\n"))
           == ["subject": "Hola José", "from": "a@example.test"])

let quoted = MailMIME.from(#""María \"Majo\" Pérez" <maria@example.test>"#)
expect("Quoted sender with escaped quotes", quoted.name == "María \"Majo\" Pérez" && quoted.address == "maria@example.test")
let display = MailMIME.from("José Reyes <jose@gmail.com>")
expect("Unquoted sender", display.name == "José Reyes" && display.address == "jose@gmail.com")
let bare = MailMIME.from("  equipo@empresa.example  ")
expect("Bare Workspace address falls back to address",
       bare.name == "equipo@empresa.example" && bare.address == "equipo@empresa.example")
let encoded = MailMIME.from("=?UTF-8?Q?Luc=C3=ADa_Garc=C3=ADa?= <lucia@example.test>")
expect("Encoded sender display name", encoded.name == "Lucía García" && encoded.address == "lucia@example.test")

let slot = MailAvatar.paletteIndex(for: "lucia@example.test", count: 8)
expect("Avatar color is stable and ignores case and spaces",
       (0..<8).contains(slot) && MailAvatar.paletteIndex(for: "  Lucia@Example.TEST ", count: 8) == slot
       && MailAvatar.paletteIndex(for: "lucia@example.test", count: 8) == 7)
expect("Avatar colors spread across the palette",
       Set((0..<64).map { MailAvatar.paletteIndex(for: "sender\($0)@example.test", count: 8) }).count == 8
       && MailAvatar.paletteIndex(for: "x@example.test", count: 0) == 0)
expect("Avatar initials: first and last name, accents, quotes and parentheses",
       MailAvatar.initials(name: "lucía garcía", address: "") == "LG"
       && MailAvatar.initials(name: #""María "Majo" Pérez""#, address: "") == "MP"
       && MailAvatar.initials(name: "Ana (via Google Docs)", address: "") == "A"
       && MailAvatar.initials(name: "Amazon.com", address: "") == "A")
expect("Avatar initials fall back to the address, then to nothing",
       MailAvatar.initials(name: "", address: "equipo@empresa.example") == "E"
       && MailAvatar.initials(name: "📬", address: "_x@example.test") == "X"
       && MailAvatar.initials(name: "", address: "") == "")
expect("Blank sender display name falls back to address",
       MailMIME.from("\"\" <hola@example.test>").name == "hola@example.test")

let qp = wire("Ma=C3=B1ana=20iremos=\r\n al cine=2E\r\nGracias,=\n equipo_1")
expect("Quoted-printable octets and CRLF/LF soft breaks",
       MailMIME.decodeTransfer(qp, encoding: "Quoted-Printable") == wire("Mañana iremos al cine.\r\nGracias, equipo_1"))
let binary = Data([0, 0xff, 0xf1, 0x0a])
let b64 = binary.base64EncodedString()
expect("Base64 transfer preserves bytes and accepts wrapped lines",
       MailMIME.decodeTransfer(wire(String(b64.prefix(4)) + "\r\n" + b64.dropFirst(4)), encoding: "base64") == binary)
expect("Latin-1 conversion",
       MailMIME.decodeCharset(Data([0x66, 0xE1, 0x63, 0x69, 0x6C]), charset: "iso-8859-1") == "fácil")
expect("Windows-1252 conversion",
       MailMIME.decodeCharset(Data([0x93, 0x80, 0x94]), charset: "cp1252") == "“€”")
expect("Unknown charset keeps valid UTF-8",
       MailMIME.decodeCharset(wire("Bogotá 📬"), charset: "x-unknown") == "Bogotá 📬")

let nested = crlf("""
    MIME-Version: 1.0
    Content-Type: multipart/mixed;
     boundary="mixed_908"

    Multipart preamble.
    --mixed_908
    Content-Type: text/plain; charset=UTF-8
    Content-Disposition: attachment; filename="notas.txt"

    Attachment text.
    --mixed_908
    Content-Type: multipart/alternative; boundary=alt_679

    --alt_679
    Content-Type: text/html; charset=UTF-8

    <p>Otra versión &ntilde;</p>
    --alt_679
    Content-Type: text/plain; charset=ISO-8859-1
    Content-Transfer-Encoding: quoted-printable

    Hola, I=F1aki.

    Reuni=F3n a las 3=2E
    --alt_679--
    --mixed_908
    Content-Type: application/pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQ=
    --mixed_908--
    Multipart epilogue.
    """)
expect("Nested mixed and alternative prefer the plain body, excluding attachments",
       MailMIME.plainText(nested) == "Hola, Iñaki.\n\nReunión a las 3.")

let htmlOnly = crlf("""
    From: Equipo <equipo@example.test>
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: base64

    \(wire("""
        <html><head><title>hidden title</title></head><body>
        <style type="text/css">p { color: red }</style><!-- hidden comment -->
        <p data-test="a>b">¡Hola, <strong>Luc&iacute;a</strong>!&nbsp;&#x1F4EC;</p>
        <script>let secret = 'hidden script';</script>
        <p>El costo es &euro;5 &amp; el env&iacute;o es gratis.<br>Adi&oacute;s.</p>
        </body></html>
        """).base64EncodedString())
    """)
let htmlText = MailMIME.plainText(htmlOnly)
expect("HTML-only fallback removes script, style, comments, and head",
       !htmlText.contains("hidden") && !htmlText.contains("color"))
expect("HTML entities, emoji, paragraphs, and line breaks",
       htmlText == "¡Hola, Lucía! 📬\n\nEl costo es €5 & el envío es gratis.\nAdiós.")
expect("HTML entities are decoded once without interpreting escaped markup",
       MailMIME.htmlText("&lt;b&gt;mensaje&lt;/b&gt; &amp;ntilde; &#241; &Aacute;") == "<b>mensaje</b> &ntilde; ñ Á")
expect("HTML falls back when the plain alternative is empty",
       MailMIME.plainText(wire("""
           Content-Type: multipart/alternative; boundary=Gmail_123

           --Gmail_123
           Content-Type: text/plain

           --Gmail_123
           Content-Type: text/html

           <p>Hola de nuevo</p>
           --Gmail_123--
           """)) == "Hola de nuevo")
expect("A default MIME part with empty headers keeps both paragraphs",
       MailMIME.plainText(crlf("\nHola.\n\nSegunda parte.")) == "Hola.\n\nSegunda parte.")
expect("Snippet collapses whitespace and counts characters",
       MailMIME.snippet(wire(" Hola\t   tú\r\n" + String(repeating: "📬", count: 150)), headers: [:])
           == "Hola tú " + String(repeating: "📬", count: 132))
expect("Snippet decodes the visible prefix of truncated Base64",
       MailMIME.snippet(wire("SG9sYQ"), headers: ["content-transfer-encoding": "base64"]) == "Hola")
expect("Snippet stops before an incomplete quoted-printable octet",
       MailMIME.snippet(wire("Hola=C"), headers: ["content-transfer-encoding": "quoted-printable"]) == "Hola")
expect("Snippet trims an incomplete UTF-8 character",
       MailMIME.snippet(wire("Buzón ") + Data([0xf0, 0x9f]), headers: ["content-type": "text/plain; charset=utf-8"]) == "Buzón")
expect("Snippet omits a non-text part",
       MailMIME.snippet(wire("JVBERi0="), headers: ["content-type": "application/pdf"]) == "")

let fetchHeader = crlf("From: =?UTF-8?Q?I=C3=B1aki?= <hola@example.test>\nSubject: Hola\n\n")
let fetchBody = crlf("C42 OK is body text\nHola, María.") + Data([0, 0xff])
let fetchWire = wire(#"* 15 FETCH (X-GM-THRID 1631481101626866771 UID 924 FLAGS (\Seen custom) INTERNALDATE " 8-Nov-2026 07:30:05 -0500" BODY[HEADER.FIELDS (FROM SUBJECT DATE)] "#)
    + wire("{\(fetchHeader.count)}\r\n") + fetchHeader
    + wire(" BODY[1]<0> {\(fetchBody.count)}\r\n") + fetchBody
    + wire(" X-GM-MSGID 18446744073709551614)\r\nC42 OK FETCH completed\r\n")
var fragmented = MailIMAPFramer()
var frames: [MailIMAPResponse] = []
for byte in fetchWire {
    fragmented.append(Data([byte]))
    while let frame = try fragmented.next() { frames.append(frame) }
}
expect("Framer handles one-byte network chunks and a tag embedded in a literal",
       frames.count == 2 && frames.last?.line == "C42 OK FETCH completed")
let fetch = frames.first?.fetch
expect("FETCH section with parentheses stays one token", frames.first?.tokens.contains(.atom("BODY[HEADER.FIELDS (FROM SUBJECT DATE)]")) == true)
expect("FETCH UID", fetch?.uid == 924)
expect("FETCH FLAGS", fetch?.flags == ["\\SEEN", "CUSTOM"])
expect("FETCH Gmail 64-bit thread ID", fetch?.threadID == 1_631_481_101_626_866_771)
expect("FETCH Gmail unsigned message ID", fetch?.messageID == UInt64.max - 1)
expect("FETCH INTERNALDATE honors day padding and timezone",
       fetch?.internalDate == ISO8601DateFormatter().date(from: "2026-11-08T12:30:05Z"))
expect("FETCH first literal respects byte length", fetch?.body("HEADER.FIELDS (FROM SUBJECT DATE)") == fetchHeader)
expect("FETCH second literal preserves NUL and non-UTF-8 bytes", fetch?.body("1", partial: true) == fetchBody)

var pipelined = MailIMAPFramer()
let listName = wire("[Gmail]/Papelera")
pipelined.append(wire(#"* LIST (\HasNoChildren \All) "/" "[Gmail]/Todos""# + "\r\n")
    + wire(#"* LIST (\Trash) "/" "# + "{\(listName.count)}\r\n") + listName + wire("\r\n")
    + wire(#"* LIST (\Trash \Noselect) "/" "[Gmail]/Archivados""# + "\r\n")
    + wire(#"* LIST (\All) "/" "Archive \"quoted\"""# + "\r\n")
    + wire("* OK text can end with {10}\r\n* 3 FETCH (UID 34 BODY[] {0}\r\n)\r\n"))
let allBox = try pipelined.next()
let trashBox = try pipelined.next()
let unavailableBox = try pipelined.next()
let quotedBox = try pipelined.next()
let status = try pipelined.next()
let empty = try pipelined.next()
let end = try pipelined.next()
expect("LIST discovers a Spanish All Mail folder", allBox?.mailbox?.name == "[Gmail]/Todos" && allBox?.mailbox?.isAll == true)
expect("LIST discovers a literal Spanish Trash folder", trashBox?.mailbox?.name == "[Gmail]/Papelera" && trashBox?.mailbox?.isTrash == true)
expect("LIST skips a nonselectable special-use folder", unavailableBox?.mailbox?.isTrash == false)
expect("LIST unescapes quoted names", quotedBox?.mailbox?.name == "Archive \"quoted\"")
expect("Braces in status text are not literal markers", status?.line == "* OK text can end with {10}")
expect("Zero-length literal is distinct from NIL", empty?.fetch?.body("") == Data() && end == nil)

expect("App password accepts four spaced groups",
       MailCredentialCheck.looksLikeAppPassword("abcd efgh ijkl mnop"))
expect("App password accepts 16 unspaced ASCII letters",
       MailCredentialCheck.looksLikeAppPassword("abcdefghijklmnop"))
expect("App password strips mixed whitespace and preserves case",
       MailCredentialCheck.normalizeAppPassword("Abcd\tEfgh\u{00A0}Ijkl\nMnop") == "AbcdEfghIjklMnop")
expect("App password rejects 15 letters", !MailCredentialCheck.looksLikeAppPassword("abcdefghijklmno"))
expect("App password rejects digits and symbols", !MailCredentialCheck.looksLikeAppPassword("MyGmailPass123!?"))
expect("App password rejects non-ASCII letters", !MailCredentialCheck.looksLikeAppPassword("ábcdefghijklmnop"))
expect("App password rejects empty input", !MailCredentialCheck.looksLikeAppPassword(""))

let suggestions: [(String, MailProvider)] = [
    (" QA@ICLOUD.COM ", .icloud), ("qa@me.com", .icloud), ("qa@mac.com", .icloud),
    ("qa@yahoo.com", .yahoo), ("qa@yahoo.co.uk", .yahoo), ("qa@yahoo.es", .yahoo),
    ("qa@ymail.com", .yahoo), ("qa@rocketmail.com", .yahoo),
    ("qa@company.example", .gmail), ("qa@notyahoo.com", .gmail)
]
for (email, provider) in suggestions {
    expect("Provider suggestion for \(email)", MailProvider.suggested(for: email) == provider)
}
for domain in ["icloud.com", "me.com", "mac.com"] {
    expect("iCloud signs in with the mailbox name for \(domain)",
           MailProvider.icloud.username(for: "qa@\(domain)") == "qa")
}
expect("iCloud uses the full address for a custom domain",
       MailProvider.icloud.username(for: "qa@company.example") == "qa@company.example")
expect("Gmail and Yahoo sign in with the full address",
       MailProvider.gmail.username(for: "qa@company.example") == "qa@company.example"
       && MailProvider.yahoo.username(for: "qa@yahoo.es") == "qa@yahoo.es")
for provider in MailProvider.allCases {
    expect("\(provider) accepts 16 spaced letters and rejects symbols and digits",
           provider.looksLikeAppPassword("abcd efgh ijkl mnop")
           && !provider.looksLikeAppPassword("abc!efghijklmnop")
           && !provider.looksLikeAppPassword("abc1efghijklmnop"))
    expect("\(provider) handles hyphenated passwords",
           provider.looksLikeAppPassword("Abcd-Efgh- Ijkl-Mnop") == (provider == .icloud))
}
let normalizedApplePassword = MailProvider.icloud.normalizeAppPassword("Abcd-Efgh- Ijkl-Mnop")
expect("iCloud normalizes separators and sends the generated form",
       normalizedApplePassword == "AbcdEfghIjklMnop"
       && MailProvider.icloud.passwordForLogin(normalizedApplePassword) == "Abcd-Efgh-Ijkl-Mnop")

func listedMailboxes(_ listing: String) throws -> [MailIMAPMailbox] {
    var framer = MailIMAPFramer()
    framer.append(crlf(listing + "\n"))
    var boxes: [MailIMAPMailbox] = []
    while let response = try framer.next() {
        if let mailbox = response.mailbox { boxes.append(mailbox) }
    }
    return boxes
}

let archiveBoxes = try listedMailboxes("""
    * LIST (\\All) "/" "[Gmail]/Todos"
    * LIST () "/" Archivo
    * LIST (\\Archive \\Noselect) "/" Container
    * LIST (\\Archive) "/" Saved
    """)
expect("Gmail archives to All Mail", MailIMAPMailbox.archive(in: archiveBoxes, provider: .gmail)?.name == "[Gmail]/Todos")
expect("iCloud and Yahoo prefer special-use Archive over named mailboxes",
       MailIMAPMailbox.archive(in: archiveBoxes, provider: .icloud)?.name == "Saved"
       && MailIMAPMailbox.archive(in: archiveBoxes, provider: .yahoo)?.name == "Saved")
expect("Non-Gmail archive falls back to Archivo",
       MailIMAPMailbox.archive(in: Array(archiveBoxes.dropLast()), provider: .icloud)?.name == "Archivo")
let namedArchive = try listedMailboxes(#"* LIST () "/" Archive"#)
expect("Yahoo can fall back to Archive", MailIMAPMailbox.archive(in: namedArchive, provider: .yahoo)?.name == "Archive")
expect("Yahoo cannot archive without an archive mailbox",
       MailIMAPMailbox.archive(in: [archiveBoxes[0], archiveBoxes[2]], provider: .yahoo) == nil)
let trashBoxes = try listedMailboxes("""
    * LIST (\\Noselect) "/" Trash
    * LIST () "/" "Deleted Messages"
    * LIST (\\Trash) "/" Bin
    """)
expect("Trash prefers special-use and falls back to a selectable named mailbox",
       MailIMAPMailbox.trash(in: trashBoxes)?.name == "Bin"
       && MailIMAPMailbox.trash(in: Array(trashBoxes.dropLast()))?.name == "Deleted Messages")

let serverCases: [(String, MailServerError)] = [
    ("A01 NO [AUTHENTICATIONFAILED] Username and password not accepted", .authenticationFailed),
    ("A01 NO Invalid credentials (Failure)", .authenticationFailed),
    ("A01 NO [ALERT] Application-specific password required: https://support.google.com/accounts", .appPasswordRequired),
    ("A01 NO [AUTHENTICATIONFAILED] Application-specific password required", .appPasswordRequired),
    ("A01 NO IMAP access is disabled for your domain", .blocked),
    ("A01 NO [ALERT] Web login required: https://accounts.google.com", .blocked),
    ("* NO [ALERT] Ask your Google Workspace administrator to enable access", .blocked),
    ("A01 NO Your account is not enabled for IMAP use.", .blocked),
    ("* BYE [UNAVAILABLE] Temporary System Error", .offline),
    ("A01 NO [AUTHENTICATIONFAILED]", .authenticationFailed),
    ("A01 NO LOGIN failed", .authenticationFailed),
    ("A01 NO App-specific password required", .appPasswordRequired)
]
for (index, test) in serverCases.enumerated() {
    expect("Server error classification \(index + 1): \(test.1)", MailServerError.classify(test.0) == test.1)
}

for (response, category) in serverCases.prefix(4) {
    let failure = MailFailure.from(MailIMAPError.server(MailServerError.classify(response)))
    let expected = tx("Cala needs an app password to sign in. Create a new one in your mail account’s security settings and try again.",
                      "Cala necesita una contraseña de aplicación para iniciar sesión. Crea una nueva en la configuración de seguridad de tu cuenta de correo y vuelve a intentarlo.")
    expect("Auth guidance for \(category): \(response.contains("[AUTHENTICATIONFAILED]") ? "tagged" : "untagged")",
           failure.localizedDescription == expected && failure.status == .authFailed(expected))
}

let mixedHeaders = ["content-type": "multipart/mixed; boundary=outside"]
let mixedBody = crlf("""
    --outside
    Content-Type: application/pdf
    Content-Disposition: attachment

    ignored
    --outside
    Content-Type: multipart/alternative; boundary=inside

    --inside
    Content-Type: text/html

    <p>alternative</p>
    --inside
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: base64

    SG9sYQ
    """)
expect("Preview finds later nested text and decodes a partial final part",
       MailMIME.snippet(mixedBody, headers: mixedHeaders) == "Hola")
let related = crlf("Content-Type: multipart/related; boundary=b; start=\"<root>\"\n\n--b\nContent-Type: text/plain\nContent-ID: <resource>\n\nResource\n--b\nContent-Type: text/html\nContent-ID: <root>\n\n<p>Root</p>\n--b--")
expect("Related body honors the root Content-ID", MailMIME.plainText(related) == "Root")
let alternativeContent = MailMIME.content(nested)
expect("Reader chooses the HTML alternative and keeps the readable plain alternative",
       alternativeContent.html?.contains("<p>Otra versión &ntilde;</p>") == true
           && alternativeContent.text == "Hola, Iñaki.\n\nReunión a las 3.")

let richRelated = crlf("""
    Content-Type: multipart/related; boundary=images; start="<root@example.test>"

    --images
    Content-Type: image/png
    Content-ID: <Logo@example.test>
    Content-Transfer-Encoding: base64

    AAEC
    --images
    Content-Type: text/html
    Content-ID: <root@example.test>

    <html lang="es"><head><style>td { color: red }</style><meta http-equiv="refresh" content="0;url=https://example.test"><base href="https://example.test"></head>
    <body><script>ignored()</script><iframe src="https://example.test">ignored</iframe><object>ignored</object><embed src="https://example.test">
    <table style="width: 100%"><tr><td OnClick="ignored()"><span style="background-image: url(cid:Logo@example.test)"></span><img src="cid:logo%40example.test" onerror="ignored()">
    <img src="https://example.test/banner.png"><img src="data:image/gif;base64,AAEC">
    <a href="java&#x09;script&#58;ignored()">Enlace</a><a href="https://example.test/?a=1&amp;b=2">Ver</a>
    <form action="https://example.test">Contenido</form></td></tr></table></body></html>
    --images--
    """)
let sanitized = MailMIME.content(richRelated).html ?? ""
let resourceLinks = MailMIME.content(crlf("""
    Content-Type: text/html

    <img src="file:///unavailable"><p style="background:url(file:///unavailable)">Local</p>
    <a href="tel:123">Phone</a><a href="mailto:reader@example.test">Email</a>
    <img src="//example.test/banner.png"><a href="//example.test/news">News</a>
    """)).html ?? ""
expect("Reader removes local resources and keeps supported external links absolute",
       !resourceLinks.contains("file:") && !resourceLinks.contains("tel:")
           && resourceLinks.contains("mailto:reader@example.test")
           && resourceLinks.contains("https://example.test/banner.png")
           && resourceLinks.contains("https://example.test/news"))
expect("Related CID percent-decodes the ID and inlines the image transfer bytes",
       sanitized.contains(#"<img src="data:image/png;base64,AAEC">"#) && !sanitized.contains("cid:"))
expect("CID background images in inline CSS use the same related resources",
       sanitized.contains("background-image: url(&quot;data:image/png;base64,AAEC&quot;)"))
expect("Sanitizer keeps head styles, tables, inline styling, and HTTP and data images",
       sanitized.contains("<html lang=\"es\"><head><meta charset=\"utf-8\">")
           && sanitized.contains("<style>td { color: red }</style></head>")
           && sanitized.contains(#"<table style="width: 100%">"#)
           && sanitized.contains(#"<img src="https://example.test/banner.png">"#)
           && sanitized.contains(#"<img src="data:image/gif;base64,AAEC">"#))
expect("Sanitizer strips active tags, event handlers, and JavaScript URLs while preserving form text",
       !["<script", "<iframe", "<object", "<embed", "<form", "<base", "refresh", "onclick",
          "onerror", "ignored", "java&#"].contains(where: sanitized.contains)
           && sanitized.contains("Contenido") && sanitized.contains("<a>Enlace</a>")
           && sanitized.contains(#"<a href="https://example.test/?a=1&amp;b=2">Ver</a>"#))

let largeRelated = crlf("""
    Content-Type: multipart/related; boundary=big

    --big
    Content-Type: text/html

    <img src="cid:big"><img src="cid:small">
    --big
    Content-Type: image/png
    Content-ID: <big>

    """) + wire("\r\n") + Data(repeating: 65, count: 8 * 1024 * 1024) + crlf("""

    --big
    Content-Type: image/png
    Content-ID: <small>
    Content-Transfer-Encoding: base64

    AAEC
    --big--
    """)
let boundedHTML = MailMIME.content(largeRelated).html ?? ""
expect("CID budget skips large images and still uses later small images",
       boundedHTML.contains(#"<img><img src="data:image/png;base64,AAEC">"#))
expect("Plain-only messages have no HTML representation",
       MailMIME.content(wire("Content-Type: text/plain\r\n\r\nHola")) == MailContent(html: nil, text: "Hola"))

let previewHTML = "<head><title>Hidden</title><style>p { display: block }</style></head><p>Hola <b>Cala</b>.</p>"
expect("HTML-only preview ignores head and style", MailMIME.snippet(wire(previewHTML),
       headers: ["content-type": "text/html"]) == "Hola Cala.")
expect("Base64 HTML preview derives meaningful text",
       MailMIME.snippet(wire(wire(previewHTML).base64EncodedString()),
                        headers: ["content-type": "text/html", "content-transfer-encoding": "base64"]) == "Hola Cala.")
expect("ISO-8859-1 quoted-printable HTML preview decodes the charset and a truncated escape",
       MailMIME.snippet(wire("<div>Reuni=F3n ma=F1ana</div>=E"),
                        headers: ["content-type": "text/html; charset=ISO-8859-1",
                                  "content-transfer-encoding": "quoted-printable"]) == "Reunión mañana")
let cutBoundary = crlf("--example-boundary\nContent-Type: text/html\nContent-Transfer-Encoding: base64\n\n"
    + String(wire("<p>Hola Cala</").base64EncodedString().dropLast(3)) + "\n--example-bou")
expect("Truncated multipart boundary preserves a truncated Base64 HTML prefix",
       MailMIME.snippet(cutBoundary, headers: ["content-type": "multipart/mixed; boundary=example-boundary"])
           == "Hola Cala")
let forwarded = crlf("""
    --fwd
    Content-Type: message/rfc822
    Content-Disposition: attachment; filename="forwarded.eml"

    From: outer@example.test
    Subject: Forwarded note
    Content-Type: text/html

    <p>Forwarded text.</p>
    --fwd--
    """)
expect("Preview falls back to an attached forwarded message and omits its headers",
       MailMIME.snippet(forwarded, headers: ["content-type": "multipart/mixed; boundary=fwd"]) == "Forwarded text.")
expect("Image-only HTML preview is empty",
       MailMIME.snippet(wire(#"<img src="cid:logo" alt="Logo">"#), headers: ["content-type": "text/html"]) == "")

let separateText = crlf("Content-Type: multipart/mixed; boundary=b\n\n--b\n\nFirst\n--b\n\nSecond\n--b--")
expect("Reader keeps separate inline sections", MailMIME.plainText(separateText) == "First\n\nSecond")
expect("Preview preserves undeclared single-byte accents",
       MailMIME.snippet(Data([0x66, 0xE9]), headers: [:]) == "fé")
expect("FETCH accepts equivalent reordered header field names",
       fetch?.body("HEADER.FIELDS (DATE FROM SUBJECT)") == fetchHeader)
expect("Workspace policy without ALERT", MailServerError.classify("NO IMAP is disabled by your administrator") == .blocked)
expect("Explicit authorization failure", MailServerError.classify("NO [AUTHORIZATIONFAILED]") == .blocked)
expect("Untagged password rejection", MailServerError.classify("* NO Username and password not accepted") == .authenticationFailed)
var statusFramer = MailIMAPFramer()
statusFramer.append(wire("* OK FETCH completed {12}\r\n* 8 FETCH (FLAGS (abc[) UID 42)\r\n"))
let statusFrame = try statusFramer.next()
let keywordFrame = try statusFramer.next()
expect("FETCH in response text cannot consume the following frame", statusFrame?.line == "* OK FETCH completed {12}")
expect("Bracket in a flag does not swallow UID", keywordFrame?.fetch?.uid == 42)

var limited = MailIMAPFramer(maxResponseSize: 12)
limited.append(wire("* OK 12345\r\n* OK 56789\r\n"))
let withinLimit = try [limited.next(), limited.next()]
expect("Response limit applies to individual frames in one network read", withinLimit.allSatisfy { $0 != nil })
limited.append(wire("* 1 FETCH (BODY[] {99999999999999999999999999999999}\r\n"))
do {
    _ = try limited.next()
    expect("Oversized frame is rejected", false)
} catch MailIMAPFramer.Failure.responseTooLarge {
    expect("Oversized frame is rejected", true)
}

let accountLink = MailService.inboxURL(accountID: "qa+one@example.test", thread: 0x123abc)
let components = URLComponents(url: accountLink, resolvingAgainstBaseURL: false)
expect("Gmail uses the selected account and hexadecimal thread", components?.queryItems?.first?.value == "qa+one@example.test"
       && accountLink.absoluteString.contains("%2B") && components?.fragment == "all/123abc")
let setupEmail = " QA+Mail@example.test "
let setupLinks = [
    (MailProvider.gmailTwoStepURL(for: setupEmail), "https://myaccount.google.com/signinoptions/two-step-verification"),
    (MailProvider.gmail.appPasswordsURL(for: setupEmail), "https://myaccount.google.com/apppasswords"),
    (MailProvider.icloud.appPasswordsURL(), "https://account.apple.com/"),
    (MailProvider.yahoo.appPasswordsURL(), "https://login.yahoo.com/myaccount/security/")
]
for (url, endpoint) in setupLinks {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    if url.host == "myaccount.google.com" {
        expect("Google setup link selects the entered account for \(url.path)",
               parts?.queryItems == [URLQueryItem(name: "authuser", value: "qa+mail@example.test")]
               && url.absoluteString.contains("%2B"))
    }
    parts?.query = nil
    expect("Setup link uses the official HTTPS endpoint \(endpoint)", parts?.url?.absoluteString == endpoint)
}
let accountMetadata = MailAccount(id: "qa@example.test", label: "QA", colorIndex: 1, enabled: true)
let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(accountMetadata)) as? [String: Any]
expect("Only account metadata can enter the JSON file",
       Set(metadata?.keys.map { $0 } ?? []) == ["id", "label", "colorIndex", "enabled", "provider"])
let legacyAccount = try JSONDecoder().decode(MailAccount.self, from: wire(
    #"{"id":"qa@me.com","label":"QA","colorIndex":1,"enabled":true}"#
))
expect("Legacy JSON without a provider remains Gmail even for a recognized domain",
       legacyAccount == MailAccount(id: "qa@me.com", label: "QA", colorIndex: 1, enabled: true, provider: .gmail))
var yahooAccount = accountMetadata
yahooAccount.provider = .yahoo
let decodedYahooAccount = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(yahooAccount))
expect("Account JSON round-trips the chosen provider", decodedYahooAccount == yahooAccount)
expect("iCloud and Yahoo open their web inboxes even if given a message ID",
       MailProvider.icloud.webInboxURL(accountID: "qa@me.com", thread: 42).absoluteString == "https://www.icloud.com/mail"
       && MailProvider.yahoo.webInboxURL(accountID: "qa@yahoo.es", thread: 42).absoluteString == "https://mail.yahoo.com")

// Exercise the production command stream without opening a socket or consulting Keychain.
// A write before the previous reply was consumed (in particular before '+' or tagged DONE) fails the transcript.
private final class MailTranscript: MailIMAPTransport {
    struct Exchange {
        let command: String
        let reply: String
        init(_ command: String, _ reply: String) { self.command = command; self.reply = reply }
    }

    private var exchanges: ArraySlice<Exchange>
    private var input = MailIMAPFramer()
    private let lock = NSLock()
    private var interrupted = false
    private var closed = false
    private var waiting: Bool?
    var isWaiting: Bool { lock.withLock { waiting == true } }
    var isWaitingForReply: Bool { lock.withLock { waiting == false } }
    var isClosed: Bool { lock.withLock { closed } }
    private var mismatch = false
    init(_ exchanges: [Exchange]) { self.exchanges = exchanges[...] }
    func start() { input.append(wire("* OK ready\r\n")) }
    func close() { lock.withLock { closed = true } }
    func interrupt() { lock.withLock { interrupted = true } }

    func send(_ text: String) {
        guard (try? input.next()) == nil, let step = exchanges.popFirst(),
              text == step.command + "\r\n" else { mismatch = true; return }
        input.append(wire(step.reply))
    }
    func receive(until deadline: DispatchTime, interruptible: Bool) async throws -> MailIMAPResponse? {
        guard !mismatch else { throw MailIMAPError.invalidResponse }
        if let frame = try input.next() { return frame }
        lock.withLock { waiting = interruptible }
        defer { lock.withLock { waiting = nil } }
        while DispatchTime.now() < deadline {
            if isClosed { throw MailIMAPError.disconnected }
            let wake = lock.withLock {
                if interruptible && interrupted { interrupted = false; return true }
                return false
            }
            if wake { return nil }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MailIMAPError.timedOut
    }
    var completed: Bool { !mismatch && exchanges.isEmpty && (try? input.next()) == nil }
}

var unsolicited = MailIMAPFramer()
unsolicited.append(wire("* STATUS {5}\r\nBox A (MESSAGES 2)\r\nC1 OK status\r\n"))
let statusParts = try unsolicited.next()?.tokens
let taggedStatus = try unsolicited.next()
expect("An unsolicited STATUS literal stays in its own response",
       statusParts?.contains(.literal(wire("Box A"))) == true && taggedStatus?.line == "C1 OK status")
expect("Advertised Central European charset is decoded", MailMIME.decodeCharset(Data([0xA3]), charset: "iso-8859-2") == "Ł")

private typealias Exchange = MailTranscript.Exchange
private func handshake(_ capabilities: String, account: String = "unit@example.test",
                       wirePassword: String = #"a\"b\\c"#) -> [Exchange] {
    [Exchange(#"C1 LOGIN "\#(account)" "\#(wirePassword)""#, "C1 OK signed in\r\n"),
     Exchange("C2 CAPABILITY", "* CAPABILITY IMAP4rev1 " + capabilities + "\r\nC2 OK capabilities\r\n"),
     Exchange("C3 SELECT INBOX", "* OK [UIDVALIDITY 7] epoch\r\n* 1 EXISTS\r\nC3 OK [READ-WRITE] selected\r\n")]
}

private func checkIMAP() async throws {
    let account = "unit@example.test"
    let fields = "HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING CONTENT-DISPOSITION)"
    let header = "Subject: Test\r\nContent-Type: text/plain\r\n\r\n"
    let preview = "Hola"
    let incoming = "* 1 FETCH (BODY[\(fields)] {\(header.utf8.count)}\r\n\(header) BODY[TEXT]<0> {4}\r\n\(preview) UID 42)\r\n"
    let listing = #"* LIST (\All) "/" "[Gmail]/Env&AO0-os""# + "\r\n" + #"* LIST (\Trash) "/" "[Gmail]/Papelera""# + "\r\n"
    let stream = MailTranscript(handshake("IDLE MOVE X-GM-EXT-1") + [
        Exchange(#"C4 LIST "" "*""#, listing + "C4 OK listed\r\n"),
        Exchange("C5 NOOP", "C5 OK synced\r\n"),
        Exchange("C6 FETCH 1:* (UID INTERNALDATE X-GM-THRID X-GM-MSGID BODY.PEEK[\(fields)] BODY.PEEK[TEXT]<0.16384>)", incoming + "C6 OK fetched\r\n"),
        Exchange("C7 UID SEARCH UNSEEN", "* SEARCH 8 42 42\r\nC7 OK searched\r\n"),
        Exchange("C8 IDLE", "* 2 EXISTS\r\n+ idling\r\n"),
        Exchange("DONE", "* 1 FETCH (UID 42 FLAGS ())\r\nC8 OK completed\r\n"),
        Exchange("C9 IDLE", "+ idling\r\n"),
        Exchange("DONE", "C9 OK completed\r\n"),
        Exchange("C10 UID FETCH 42 (UID RFC822.SIZE)", "* 2 FETCH (UID 42 RFC822.SIZE \(richRelated.count))\r\nC10 OK size\r\n"),
        Exchange("C11 UID FETCH 42 (UID BODY.PEEK[])", "* 1 FETCH (UID 21 BODY[] {3}\r\nold)\r\n* 2 FETCH (BODY[] {\(richRelated.count)}\r\n\(String(decoding: richRelated, as: UTF8.self)) UID 42)\r\nC11 OK fetched\r\n"),
        Exchange(#"C12 UID STORE 42 +FLAGS.SILENT (\Seen)"#, "C12 OK stored\r\n"),
        Exchange("C13 UID SEARCH UNSEEN", "* SEARCH 7 5\r\nC13 OK searched\r\n"),
        Exchange(#"C14 UID STORE 5,7 +FLAGS.SILENT (\Seen)"#, "C14 OK stored\r\n"),
        Exchange(#"C15 LIST "" "*""#, listing + "C15 OK listed\r\n"),
        Exchange(#"C16 UID MOVE 42 "[Gmail]/Env&AO0-os""#, "* 1 EXPUNGE\r\nC16 OK moved\r\n")
    ])
    let connection = MailIMAP(socket: stream)
    try await connection.open(email: account, password: #"a"b\c"#)
    let inbox = try await connection.synchronize(accountID: account)
    guard let message = inbox.messages.first else { throw MailIMAPError.invalidResponse }
    expect("Snapshot uses global unseen UIDs and PEEK preview", inbox.unread == 2 && message.unread && message.snippet == preview)
    expect("Message identity includes UIDVALIDITY", message.id == "\(account)#7#42")
    expect("Gmail can archive when All Mail is visible and MOVE is available", inbox.canArchive)
    try await connection.waitForInboxChange()
    connection.requestRefresh()
    try await connection.waitForInboxChange()
    let content = try await connection.content(of: message)
    expect("Reader fetches the requested UID with BODY.PEEK and no Seen write",
           content == MailMIME.content(richRelated) && message.unread)
    try await connection.markRead(message)
    try await connection.markAllRead()
    try await connection.archive(message)
    expect("Login quoting, IDLE/DONE, seen writes and localized archive transcript", stream.completed)

    let oversized = MailTranscript(handshake("") + [
        Exchange("C4 UID FETCH 42 (UID RFC822.SIZE)", "* 1 FETCH (UID 42 RFC822.SIZE 26214401)\r\nC4 OK size\r\n")
    ])
    let sizeChecked = MailIMAP(socket: oversized)
    try await sizeChecked.open(email: account, password: #"a"b\c"#)
    do {
        _ = try await sizeChecked.content(of: message)
        expect("Oversized reader content is rejected", false)
    } catch MailIMAPError.messageTooLarge {
        expect("Oversized reader content is rejected before download", oversized.completed)
    }

    let htmlHeader = "Content-Type: text/html; charset=utf-8\r\n\r\n"
    let longStyle = "<style>" + String(repeating: " ", count: 20_000) + "</style><p>After CSS</p>"
    let shortStyle = String(longStyle.prefix(16_384))
    let cssPreview = MailTranscript(handshake("") + [
        Exchange("C4 NOOP", "C4 OK\r\n"),
        Exchange("C5 FETCH 1:* (UID INTERNALDATE BODY.PEEK[\(fields)] BODY.PEEK[TEXT]<0.16384>)",
                 "* 1 FETCH (UID 42 BODY[\(fields)] {\(htmlHeader.utf8.count)}\r\n\(htmlHeader) BODY[TEXT]<0> {16384}\r\n\(shortStyle))\r\nC5 OK\r\n"),
        Exchange("C6 UID SEARCH UNSEEN", "* SEARCH 42\r\nC6 OK\r\n"),
        Exchange("C7 UID FETCH 42 (UID BODY.PEEK[TEXT]<0.262144>)",
                 "* 1 FETCH (UID 42 BODY[TEXT]<0> {\(longStyle.utf8.count)}\r\n\(longStyle))\r\nC7 OK\r\n")
    ])
    let cssConnection = MailIMAP(socket: cssPreview)
    try await cssConnection.open(email: account, password: #"a"b\c"#)
    let cssInbox = try await cssConnection.synchronize(accountID: account)
    expect("A wider PEEK preview finds text after large CSS and preserves unread state",
           cssInbox.messages.first?.snippet == "After CSS" && cssInbox.messages.first?.unread == true
               && cssPreview.completed)

    let fallback = MailTranscript(handshake("UIDPLUS") + [
        Exchange(#"C4 LIST "" "*""#, listing + "C4 OK listed\r\n"),
        Exchange(#"C5 UID COPY 42 "[Gmail]/Papelera""#, "C5 OK copied\r\n"),
        Exchange(#"C6 UID STORE 42 +FLAGS.SILENT (\Deleted)"#, "C6 OK stored\r\n"),
        Exchange("C7 UID EXPUNGE 42", "C7 OK expunged\r\n")
    ])
    let legacy = MailIMAP(socket: fallback)
    try await legacy.open(email: account, password: #"a"b\c"#)
    try await legacy.trash(message)
    expect("Trash fallback only expunges the copied UID", fallback.completed)

    let unsafe = MailTranscript(handshake("") + [Exchange(#"C4 LIST "" "*""#, listing + "C4 OK listed\r\n")])
    let restricted = MailIMAP(socket: unsafe)
    try await restricted.open(email: account, password: #"a"b\c"#)
    do {
        try await restricted.trash(message)
        expect("Unsafe expunge refused", false)
    } catch MailIMAPError.moveUnsupported { expect("Unsafe expunge refused before COPY", unsafe.completed) }
    let denied = MailTranscript(handshake("UIDPLUS") + [
        Exchange(#"C4 LIST "" "*""#, listing + "C4 OK listed\r\n"),
        Exchange(#"C5 UID COPY 42 "[Gmail]/Papelera""#, "C5 NO [OVERQUOTA] copy failed\r\n")
    ])
    let deniedConnection = MailIMAP(socket: denied)
    try await deniedConnection.open(email: account, password: #"a"b\c"#)
    do {
        try await deniedConnection.trash(message)
        expect("Rejected COPY stopped the move", false)
    } catch MailIMAPError.rejected { expect("Rejected COPY prevents flagging and expunge", denied.completed) }

    var stale = message
    stale.uidValidity = 6
    do {
        try await restricted.markRead(stale)
        expect("Old UID epoch refused", false)
    } catch MailIMAPError.staleMessage { expect("Old UID epoch refused before STORE", unsafe.completed) }

    let broken = MailTranscript(handshake("IDLE") + [Exchange("C4 IDLE", "C3 OK old tag\r\n")])
    let confused = MailIMAP(socket: broken)
    try await confused.open(email: account, password: #"a"b\c"#)
    do {
        try await confused.waitForInboxChange()
        expect("Unexpected tag refused", false)
    } catch MailIMAPError.invalidResponse { expect("Unexpected tag refused before DONE", broken.completed) }

    let iCloudPassword = "Abcd-Efgh-Ijkl-Mnop"
    let iCloud = MailTranscript([
        Exchange(#"C1 LOGIN "unit" "\#(iCloudPassword)""#, "C1 NO LOGIN failed\r\n"),
        Exchange(#"C2 LOGIN "unit@me.com" "\#(iCloudPassword)""#, "C2 OK signed in\r\n"),
        Exchange("C3 CAPABILITY", "* CAPABILITY IMAP4rev1 MOVE SPECIAL-USE\r\nC3 OK\r\n"),
        Exchange("C4 SELECT INBOX", "* OK [UIDVALIDITY 7] epoch\r\n* 1 EXISTS\r\nC4 OK selected\r\n"),
        Exchange(#"C5 LIST "" "*" RETURN (SPECIAL-USE)"#, #"* LIST (\Archive) "/" Saved"# + "\r\nC5 OK\r\n"),
        Exchange("C6 NOOP", "C6 OK\r\n"),
        Exchange("C7 FETCH 1:* (UID INTERNALDATE BODY.PEEK[\(fields)] BODY.PEEK[TEXT]<0.16384>)", incoming + "C7 OK\r\n"),
        Exchange("C8 UID SEARCH UNSEEN", "* SEARCH 42\r\nC8 OK\r\n"),
        Exchange(#"C9 LIST "" "*" RETURN (SPECIAL-USE)"#, #"* LIST (\Archive) "/" Saved"# + "\r\nC9 OK\r\n"),
        Exchange(#"C10 UID MOVE 42 "Saved""#, "* 1 EXPUNGE\r\nC10 OK\r\n")
    ])
    let apple = MailIMAP(socket: iCloud, provider: .icloud)
    try await apple.open(email: "unit@me.com", password: iCloudPassword)
    let appleInbox = try await apple.synchronize(accountID: "unit@me.com")
    guard let appleMessage = appleInbox.messages.first else { throw MailIMAPError.invalidResponse }
    expect("iCloud reports archive support and fetches without Gmail extensions", appleInbox.canArchive)
    try await apple.archive(appleMessage)
    expect("iCloud retries with full address and moves to special-use Archive", iCloud.completed)

    let yahooEmail = "unit@yahoo.es"
    let yahoo = MailTranscript(handshake("MOVE", account: yahooEmail) + [
        Exchange(#"C4 LIST "" "*""#, #"* LIST () "/" Trash"# + "\r\nC4 OK\r\n"),
        Exchange("C5 NOOP", "C5 OK\r\n"),
        Exchange("C6 FETCH 1:* (UID INTERNALDATE BODY.PEEK[\(fields)] BODY.PEEK[TEXT]<0.16384>)", incoming + "C6 OK\r\n"),
        Exchange("C7 UID SEARCH UNSEEN", "* SEARCH 42\r\nC7 OK\r\n")
    ])
    let yahooConnection = MailIMAP(socket: yahoo, provider: .yahoo)
    try await yahooConnection.open(email: yahooEmail, password: #"a"b\c"#)
    let yahooInbox = try await yahooConnection.synchronize(accountID: yahooEmail)
    expect("Yahoo signs in with the full address and reports archive unavailable without a mailbox",
           yahoo.completed && yahooInbox.messages.count == 1 && !yahooInbox.canArchive)
}

do { try await checkIMAP() } catch { expect("Production IMAP command transcript", false) }

// MARK: Mail actions at the IMAP wire level
// These pin what the SERVER sees for delete, archive and mark-read, independent of incidental commands (LIST, NOOP,
// SEARCH, FETCH ...). A scripted server answers whatever the client sends, records every command with the status it
// returned, and the checks assert the mutating commands, their order, and a set of "never" invariants.
private final class MailActionServer: MailIMAPTransport {
    struct Entry { let command: String; let status: String }

    private let capabilities: String
    private let list: String
    private let unseen: [UInt32]
    private let failing: [String: String]   // command prefix -> raw reply; "§" stands for the tag
    private var input = MailIMAPFramer()
    private(set) var entries: [Entry] = []

    init(capabilities: String, list: String, unseen: [UInt32] = [], failing: [String: String] = [:]) {
        self.capabilities = capabilities
        self.list = list
        self.unseen = unseen
        self.failing = failing
    }

    func start() { input.append(wire("* OK ready\r\n")) }
    func close() {}
    func interrupt() {}

    func send(_ text: String) {
        let line = text.trimmingCharacters(in: .newlines)
        guard let space = line.firstIndex(of: " ") else { entries.append(Entry(command: line, status: "?")); return }
        let tag = String(line[..<space]), command = String(line[line.index(after: space)...])
        let reply: String
        if let key = failing.keys.filter({ command.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
            reply = failing[key]!.replacingOccurrences(of: "§", with: tag)
        } else if command.hasPrefix("CAPABILITY") {
            reply = "* CAPABILITY IMAP4rev1 \(capabilities)\r\n\(tag) OK capabilities\r\n"
        } else if command.hasPrefix("SELECT") {
            reply = "* OK [UIDVALIDITY 7] epoch\r\n* 1 EXISTS\r\n\(tag) OK [READ-WRITE] selected\r\n"
        } else if command.hasPrefix("LIST") {
            reply = list + "\(tag) OK listed\r\n"
        } else if command.hasPrefix("UID SEARCH UNSEEN") {
            reply = "* SEARCH" + unseen.map { " \($0)" }.joined() + "\r\n\(tag) OK searched\r\n"
        } else if command.hasPrefix("UID MOVE") || command.hasPrefix("UID EXPUNGE") {
            reply = "* 1 EXPUNGE\r\n\(tag) OK done\r\n"
        } else {
            reply = "\(tag) OK done\r\n"
        }
        let status = reply.components(separatedBy: "\r\n").last(where: { $0.hasPrefix(tag + " ") })?
            .split(separator: " ").dropFirst().first.map(String.init) ?? "-"
        entries.append(Entry(command: command, status: status))
        input.append(wire(reply))
    }

    func receive(until deadline: DispatchTime, interruptible: Bool) async throws -> MailIMAPResponse? {
        if let frame = try input.next() { return frame }
        throw MailIMAPError.timedOut   // the client asked for a reply nobody sent
    }

    var commands: [String] { entries.map(\.command) }
    /// Everything except commands that cannot change mailbox state. A command this list does not know counts as mutating.
    var mutating: [String] {
        let readOnly: Set<String> = ["LOGIN", "AUTHENTICATE", "CAPABILITY", "SELECT", "EXAMINE", "LIST", "LSUB", "NOOP",
                                     "IDLE", "DONE", "SEARCH", "FETCH", "STATUS", "NAMESPACE", "ID", "ENABLE", "CHECK",
                                     "LOGOUT"]
        return entries.map(\.command).filter { command in
            let words = command.split(separator: " ").map { $0.uppercased() }
            let verb = words.first == "UID" ? (words.dropFirst().first ?? "") : (words.first ?? "")
            return !readOnly.contains(verb)
        }
    }
}

/// Server-side safety of a command log: nothing can purge messages the user did not choose.
/// - no plain EXPUNGE / CLOSE / DELETE, and no non-UID STORE, COPY, MOVE, EXPUNGE
/// - STORE \Deleted only for a UID set whose UID COPY the server already accepted
/// - UID EXPUNGE only for a UID set whose STORE \Deleted the server already accepted
func wireIsSafe(_ log: [(command: String, status: String)]) -> Bool {
    var copied: Set<String> = [], flagged: Set<String> = []
    for (command, status) in log {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        let byUID = first.uppercased() == "UID" && words.count >= 3
        let verb = (byUID ? words[1] : first).uppercased()
        switch verb {
        case "CLOSE", "DELETE": return false
        case "EXPUNGE":
            guard byUID, flagged.contains(words[2]) else { return false }
        case "COPY":
            guard byUID else { return false }
            if status == "OK" { copied.insert(words[2]) }
        case "MOVE":
            guard byUID else { return false }
        case "STORE":
            guard byUID else { return false }
            if command.lowercased().contains("\\deleted") {
                guard copied.contains(words[2]) else { return false }
                if status == "OK" { flagged.insert(words[2]) }
            }
        default: break
        }
    }
    return true
}

private func errorKind(_ error: Error?) -> String {
    switch error {
    case nil: return "none"
    case MailIMAPError.moveUnsupported?: return "moveUnsupported"
    case MailIMAPError.rejected?: return "rejected"
    case MailIMAPError.missingMailbox?: return "missingMailbox"
    case MailIMAPError.staleMessage?: return "staleMessage"
    case MailIMAPError.server?: return "server"
    default: return "other(\(String(describing: error)))"
    }
}

/// Run once with the conservative stream the transcripts pin and once with `.fast` (production): delete, archive and
/// the flag writes must be the same commands, and every wire-safety invariant must hold, under both.
private func checkMailActions(tuning: MailIMAPTuning = .conservative) async throws {
    let message = MailMessage(id: "unit@example.test#7#42", accountID: "unit@example.test", uid: 42, fromName: "A",
                              fromAddress: "a@example.test", subject: "S", snippet: "", date: .distantPast, unread: true,
                              gmailThreadID: nil, gmailMessageID: nil, uidValidity: 7)
    let gmailList = #"* LIST () "/" INBOX"# + "\r\n" + #"* LIST (\All) "/" "[Gmail]/All Mail""# + "\r\n"
        + #"* LIST (\Sent) "/" "[Gmail]/Sent Mail""# + "\r\n" + #"* LIST (\Trash) "/" "[Gmail]/Trash""# + "\r\n"

    func run(_ capabilities: String, _ list: String, provider: MailProvider = .gmail, unseen: [UInt32] = [],
             failing: [String: String] = [:], message: MailMessage = message,
             _ action: (MailIMAP, MailMessage) async throws -> Void) async -> (server: MailActionServer, error: Error?) {
        let server = MailActionServer(capabilities: capabilities, list: list, unseen: unseen, failing: failing)
        let connection = MailIMAP(socket: server, provider: provider, tuning: tuning)
        let email = provider == .gmail ? "unit@example.test" : provider == .yahoo ? "unit@yahoo.es" : "unit@me.com"
        do {
            try await connection.open(email: email, password: "pw")
            try await action(connection, message)
            return (server, nil)
        } catch { return (server, error) }
    }
    func trash(_ c: MailIMAP, _ m: MailMessage) async throws { try await c.trash(m) }
    func archive(_ c: MailIMAP, _ m: MailMessage) async throws { try await c.archive(m) }
    func safe(_ s: MailActionServer) -> Bool { wireIsSafe(s.entries.map { ($0.command, $0.status) }) }
    func neverPurges(_ s: MailActionServer) -> Bool {
        !s.commands.contains { $0.uppercased().contains("EXPUNGE") || $0.lowercased().contains("\\deleted") }
    }
    let copy3 = { (target: String) in
        [#"UID COPY 42 \#(target)"#, #"UID STORE 42 +FLAGS.SILENT (\Deleted)"#, "UID EXPUNGE 42"]
    }

    // The checker itself must be able to fail: synthetic logs that purge more than they should.
    if tuning == .conservative {
    let good = [("UID COPY 42 \"T\"", "OK"), ("UID STORE 42 +FLAGS.SILENT (\\Deleted)", "OK"), ("UID EXPUNGE 42", "OK")]
    expect("Wire safety accepts COPY, STORE \\Deleted, UID EXPUNGE of the same UID", wireIsSafe(good))
    expect("Wire safety accepts UID MOVE alone", wireIsSafe([("UID MOVE 42 \"T\"", "OK")]))
    expect("Wire safety rejects a plain EXPUNGE", !wireIsSafe(good + [("EXPUNGE", "OK")]))
    expect("Wire safety rejects CLOSE (implicit expunge)", !wireIsSafe(good + [("CLOSE", "OK")]))
    expect("Wire safety rejects STORE \\Deleted without COPY", !wireIsSafe(Array(good.dropFirst())))
    expect("Wire safety rejects STORE \\Deleted after a refused COPY", !wireIsSafe([("UID COPY 42 \"T\"", "NO")] + good.dropFirst()))
    expect("Wire safety rejects STORE \\Deleted for another UID than the copied one",
           !wireIsSafe([good[0], ("UID STORE 43 +FLAGS.SILENT (\\Deleted)", "OK")]))
    expect("Wire safety rejects UID EXPUNGE without an accepted STORE \\Deleted",
           !wireIsSafe([good[0], ("UID STORE 42 +FLAGS.SILENT (\\Deleted)", "NO"), good[2]]))
    expect("Wire safety rejects UID EXPUNGE with no STORE at all", !wireIsSafe([good[0], good[2]]))
    expect("Wire safety rejects sequence-number STORE \\Deleted", !wireIsSafe([good[0], ("STORE 42 +FLAGS (\\Deleted)", "OK")]))
    }

    // 1. Delete with MOVE.
    let gmailMove = await run("IDLE MOVE X-GM-EXT-1", gmailList, trash)
    expect("Delete with MOVE sends exactly UID MOVE to the \\Trash mailbox from LIST (Gmail layout)",
           gmailMove.server.mutating == [#"UID MOVE 42 "[Gmail]/Trash""#] && errorKind(gmailMove.error) == "none")
    expect("Delete with MOVE never sends EXPUNGE or \\Deleted", neverPurges(gmailMove.server) && safe(gmailMove.server))
    let lowercase = await run("idle move", gmailList, trash)
    expect("Capability names are case-insensitive for MOVE", lowercase.server.mutating == [#"UID MOVE 42 "[Gmail]/Trash""#])
    let both = await run("MOVE UIDPLUS", gmailList, trash)
    expect("MOVE wins over UIDPLUS: no COPY, STORE or EXPUNGE",
           both.server.mutating == [#"UID MOVE 42 "[Gmail]/Trash""#] && neverPurges(both.server))
    for name in ["Trash", "TRASH", "Deleted Messages", "Papelera"] {
        let named = await run("MOVE", #"* LIST () "/" INBOX"# + "\r\n" + #"* LIST () "/" "\#(name)""# + "\r\n", provider: .yahoo, trash)
        expect("Delete picks an unflagged mailbox named \(name)",
               named.server.mutating == [#"UID MOVE 42 "\#(name)""#] && neverPurges(named.server))
    }
    let deletedItems = await run("MOVE SPECIAL-USE", #"* LIST (\Trash) "/" "Deleted Items""# + "\r\n", provider: .icloud, trash)
    expect("Delete picks \"Deleted Items\" when it carries \\Trash (name is quoted)",
           deletedItems.server.mutating == [#"UID MOVE 42 "Deleted Items""#] && neverPurges(deletedItems.server))
    let unflagged = await run("MOVE", #"* LIST () "/" "Deleted Items""# + "\r\n", provider: .icloud, trash)
    expect("\"Deleted Items\" without \\Trash is not guessed: missing mailbox and nothing mutating",
           errorKind(unflagged.error) == "missingMailbox" && unflagged.server.mutating.isEmpty)
    let flagWins = await run("MOVE", #"* LIST () "/" Trash"# + "\r\n" + #"* LIST (\Trash) "/" Bin"# + "\r\n", provider: .yahoo, trash)
    expect("A \\Trash flag wins over a mailbox that is merely named Trash", flagWins.server.mutating == [#"UID MOVE 42 "Bin""#])
    let noselect = await run("MOVE", #"* LIST (\Trash \Noselect) "/" "[Gmail]/Trash""# + "\r\n", trash)
    expect("An unselectable \\Trash mailbox is never a target",
           errorKind(noselect.error) == "missingMailbox" && noselect.server.mutating.isEmpty)
    let noTrash = await run("MOVE", #"* LIST () "/" INBOX"# + "\r\n", trash)
    expect("No trash mailbox: error and nothing mutating",
           errorKind(noTrash.error) == "missingMailbox" && noTrash.server.mutating.isEmpty)
    let noTrashNoMove = await run("IDLE", #"* LIST () "/" INBOX"# + "\r\n", trash)
    expect("No trash mailbox and no MOVE/UIDPLUS: still an error and nothing mutating",
           noTrashNoMove.error != nil && noTrashNoMove.server.mutating.isEmpty)

    // 2. Delete without MOVE, with UIDPLUS.
    let fallback = await run("IDLE UIDPLUS", gmailList, trash)
    expect("Delete without MOVE: UID COPY, then UID STORE \\Deleted, then UID EXPUNGE of that UID only",
           fallback.server.mutating == copy3(#""[Gmail]/Trash""#) && errorKind(fallback.error) == "none")
    expect("Delete without MOVE never sends a plain EXPUNGE and passes the safety invariants",
           safe(fallback.server) && !fallback.server.commands.contains { $0.uppercased() == "EXPUNGE" })
    let fallbackNamed = await run("UIDPLUS", #"* LIST () "/" "Deleted Items""# + "\r\n" + #"* LIST (\Trash) "/" "Deleted Items""# + "\r\n",
                                  provider: .icloud, trash)
    expect("The UIDPLUS path copies to the same mailbox the MOVE path would use",
           fallbackNamed.server.mutating == copy3(#""Deleted Items""#) && safe(fallbackNamed.server))

    // 3. Delete with neither MOVE nor UIDPLUS.
    for caps in ["IDLE", "IDLE X-GM-EXT-1 SPECIAL-USE", ""] {
        let unsupported = await run(caps, gmailList, trash)
        expect("Delete with neither MOVE nor UIDPLUS (\(caps.isEmpty ? "no extensions" : caps)) fails as unsupported with nothing mutating",
               errorKind(unsupported.error) == "moveUnsupported" && unsupported.server.mutating.isEmpty
                   && neverPurges(unsupported.server))
    }

    // 4. Archive.
    let archiveMove = await run("MOVE", gmailList, archive)
    expect("Gmail archive with MOVE: UID MOVE to the \\All mailbox",
           archiveMove.server.mutating == [#"UID MOVE 42 "[Gmail]/All Mail""#] && neverPurges(archiveMove.server))
    let archiveCopy = await run("UIDPLUS", gmailList, archive)
    expect("Gmail archive without MOVE: COPY to \\All, STORE \\Deleted, UID EXPUNGE of that UID",
           archiveCopy.server.mutating == copy3(#""[Gmail]/All Mail""#) && safe(archiveCopy.server))
    let archiveNone = await run("IDLE", gmailList, archive)
    expect("Archive with neither MOVE nor UIDPLUS: unsupported, nothing mutating",
           errorKind(archiveNone.error) == "moveUnsupported" && archiveNone.server.mutating.isEmpty)
    let gmailNamed = await run("MOVE", #"* LIST () "/" Archive"# + "\r\n", archive)
    expect("Gmail archive ignores mailboxes named Archive: only \\All counts",
           errorKind(gmailNamed.error) == "missingMailbox" && gmailNamed.server.mutating.isEmpty)
    let gmailTrashOnly = await run("MOVE", #"* LIST (\Trash) "/" Trash"# + "\r\n", archive)
    expect("Archive never targets the trash mailbox", gmailTrashOnly.server.mutating.isEmpty)
    let appleArchive = await run("MOVE SPECIAL-USE", #"* LIST () "/" Archive"# + "\r\n" + #"* LIST (\Archive) "/" Saved"# + "\r\n",
                                 provider: .icloud, archive)
    expect("Non-Gmail archive: the \\Archive flag wins over a mailbox named Archive",
           appleArchive.server.mutating == [#"UID MOVE 42 "Saved""#])
    for name in ["Archive", "ARCHIVO"] {
        let named = await run("MOVE", #"* LIST () "/" "\#(name)""# + "\r\n", provider: .yahoo, archive)
        expect("Non-Gmail archive falls back to a mailbox named \(name)", named.server.mutating == [#"UID MOVE 42 "\#(name)""#])
    }
    let appleAll = await run("MOVE", #"* LIST (\All) "/" "All Mail""# + "\r\n", provider: .yahoo, archive)
    expect("Non-Gmail archive does not use \\All", errorKind(appleAll.error) == "missingMailbox" && appleAll.server.mutating.isEmpty)
    let appleCopy = await run("UIDPLUS", #"* LIST (\Archive) "/" Saved"# + "\r\n", provider: .yahoo, archive)
    expect("Non-Gmail archive without MOVE: COPY, STORE \\Deleted, UID EXPUNGE",
           appleCopy.server.mutating == copy3(#""Saved""#) && safe(appleCopy.server))

    // 5. Mark read.
    let read = await run("IDLE MOVE", gmailList) { c, m in try await c.markRead(m) }
    expect("Mark read: exactly UID STORE +FLAGS.SILENT (\\Seen) for that UID",
           read.server.mutating == [#"UID STORE 42 +FLAGS.SILENT (\Seen)"#] && errorKind(read.error) == "none")
    let readAll = await run("IDLE", gmailList, unseen: [42, 8, 42, 5]) { c, _ in try await c.markAllRead() }
    expect("Mark all read: searches UNSEEN, then one STORE of the sorted unique set",
           readAll.server.mutating == [#"UID STORE 5,8,42 +FLAGS.SILENT (\Seen)"#]
               && readAll.server.commands.contains("UID SEARCH UNSEEN"))
    let many = (1...650).map { UInt32($0) }
    let bulk = await run("IDLE", gmailList, unseen: many.reversed()) { c, _ in try await c.markAllRead() }
    func set(_ r: ClosedRange<Int>) -> String { #"UID STORE \#(r.map(String.init).joined(separator: ",")) +FLAGS.SILENT (\Seen)"# }
    expect("Mark all read splits 650 unseen UIDs into sorted batches of 300, 300 and 50",
           bulk.server.mutating == [set(1...300), set(301...600), set(601...650)])
    let none = await run("IDLE", gmailList) { c, _ in try await c.markAllRead() }
    expect("Mark all read with nothing unseen sends no STORE at all",
           none.server.mutating.isEmpty && errorKind(none.error) == "none")
    for result in [read, readAll, bulk, none] {
        expect("Mark read flags only add \\Seen, never \\Deleted, never remove flags, never expunge",
               neverPurges(result.server) && !result.server.commands.contains { $0.contains("-FLAGS") || $0.contains(" FLAGS ") })
    }

    // 6. A refusing server stops the sequence.
    let moveRefused = await run("MOVE", gmailList, failing: ["UID MOVE": "§ NO [OVERQUOTA] cannot move\r\n"], trash)
    expect("MOVE answered NO: the error surfaces and MOVE is the only mutating command",
           errorKind(moveRefused.error) == "rejected" && moveRefused.server.mutating == [#"UID MOVE 42 "[Gmail]/Trash""#]
               && neverPurges(moveRefused.server))
    let moveBad = await run("MOVE", gmailList, failing: ["UID MOVE": "§ BAD unknown command\r\n"], archive)
    expect("MOVE answered BAD: the error surfaces and nothing follows",
           errorKind(moveBad.error) == "rejected" && moveBad.server.mutating == [#"UID MOVE 42 "[Gmail]/All Mail""#]
               && neverPurges(moveBad.server))
    let moveBye = await run("MOVE", gmailList, failing: ["UID MOVE": "* BYE [UNAVAILABLE] going away\r\n"], trash)
    expect("Connection dropped by the server during MOVE: the error surfaces and nothing follows",
           errorKind(moveBye.error) == "server" && moveBye.server.mutating == [#"UID MOVE 42 "[Gmail]/Trash""#])
    let copyRefused = await run("UIDPLUS", gmailList, failing: ["UID COPY": "§ NO [OVERQUOTA] copy failed\r\n"], trash)
    expect("COPY answered NO: the error surfaces and neither STORE \\Deleted nor EXPUNGE follows",
           errorKind(copyRefused.error) == "rejected" && copyRefused.server.mutating == [#"UID COPY 42 "[Gmail]/Trash""#]
               && neverPurges(copyRefused.server))
    let copyArchiveRefused = await run("UIDPLUS", gmailList, failing: ["UID COPY": "§ NO [TRYCREATE] no such mailbox\r\n"], archive)
    expect("COPY answered NO while archiving: nothing is flagged or expunged",
           errorKind(copyArchiveRefused.error) == "rejected" && neverPurges(copyArchiveRefused.server)
               && copyArchiveRefused.server.mutating == [#"UID COPY 42 "[Gmail]/All Mail""#])
    let storeRefused = await run("UIDPLUS", gmailList, failing: ["UID STORE": "§ NO cannot store\r\n"], trash)
    expect("STORE \\Deleted answered NO: the error surfaces and no EXPUNGE follows",
           errorKind(storeRefused.error) == "rejected"
               && storeRefused.server.mutating == Array(copy3(#""[Gmail]/Trash""#).prefix(2))
               && !storeRefused.server.commands.contains { $0.uppercased().contains("EXPUNGE") } && safe(storeRefused.server))
    let expungeRefused = await run("UIDPLUS", gmailList, failing: ["UID EXPUNGE": "§ NO cannot expunge\r\n"], trash)
    expect("UID EXPUNGE answered NO: the error surfaces after the full sequence",
           errorKind(expungeRefused.error) == "rejected" && expungeRefused.server.mutating == copy3(#""[Gmail]/Trash""#)
               && safe(expungeRefused.server))
    let storeSeenRefused = await run("MOVE", gmailList, failing: ["UID STORE": "§ NO read-only\r\n"]) { c, m in try await c.markRead(m) }
    expect("Mark read answered NO: the error surfaces", errorKind(storeSeenRefused.error) == "rejected"
           && storeSeenRefused.server.mutating == [#"UID STORE 42 +FLAGS.SILENT (\Seen)"#])
    let listRefused = await run("MOVE", gmailList, failing: ["LIST": "§ NO list failed\r\n"], trash)
    expect("LIST answered NO: the delete fails before any mutating command",
           listRefused.error != nil && listRefused.server.mutating.isEmpty)

    // Stale identity: nothing is sent for a UID from another UIDVALIDITY epoch, or UID 0.
    var oldEpoch = message
    oldEpoch.uidValidity = 6
    var noEpoch = message
    noEpoch.uidValidity = nil
    let zero = MailMessage(id: "z", accountID: message.accountID, uid: 0, fromName: "", fromAddress: "", subject: "", snippet: "",
                           date: .distantPast, unread: true, gmailThreadID: nil, gmailMessageID: nil, uidValidity: 7)
    for (label, stale) in [("another UIDVALIDITY", oldEpoch), ("no UIDVALIDITY", noEpoch), ("UID 0", zero)] {
        let deleted = await run("MOVE UIDPLUS", gmailList, message: stale, trash)
        let archived = await run("MOVE UIDPLUS", gmailList, message: stale, archive)
        let marked = await run("MOVE UIDPLUS", gmailList, message: stale) { c, m in try await c.markRead(m) }
        expect("A stale message (\(label)) is refused by delete, archive and mark read before any command is sent",
               [deleted, archived, marked].allSatisfy { errorKind($0.error) == "staleMessage" && $0.server.mutating.isEmpty }
                   && !deleted.server.commands.contains { $0.hasPrefix("LIST") })
    }
}

do { try await checkMailActions() } catch { expect("Mail action wire checks ran", false) }
checkSuffix = " [.fast]"
do { try await checkMailActions(tuning: .fast) } catch { expect("Mail action wire checks ran", false) }
checkSuffix = ""

expect("Preview tolerates a truncated Base64 padding pair",
       MailMIME.snippet(wire("TQ="), headers: ["content-transfer-encoding": "base64"]) == "M")

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw MailIMAPError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func checkAccountLifecycle() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let url = temporary.appendingPathComponent("mail-accounts.json")
    let first = "unit@gmail.com", second = "other@example.test"
    let appPassword = "AbcdEfghIjklMnop"
    let fields = "HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING CONTENT-DISPOSITION)"
    func snapshot(_ tag: Int, unread: Bool) -> [Exchange] {
        [Exchange("C\(tag) NOOP", "C\(tag) OK\r\n"),
         Exchange("C\(tag + 1) FETCH 1:* (UID INTERNALDATE BODY.PEEK[\(fields)] BODY.PEEK[TEXT]<0.16384>)",
                  "* 1 FETCH (UID 42 BODY[\(fields)] {2}\r\n\r\n BODY[TEXT]<0> {4}\r\nHola)\r\nC\(tag + 1) OK\r\n"),
         Exchange("C\(tag + 2) UID SEARCH UNSEEN", (unread ? "* SEARCH 42" : "* SEARCH") + "\r\nC\(tag + 2) OK\r\n")]
    }
    let lost = MailTranscript(handshake("", account: first, wirePassword: appPassword) + snapshot(4, unread: false) + snapshot(7, unread: true) + [
        Exchange(#"C10 UID STORE 42 +FLAGS.SILENT (\Seen)"#, "* BYE [UNAVAILABLE] disconnected\r\n")
    ])
    let restored = MailTranscript(handshake("", account: first, wirePassword: appPassword) + [
        Exchange(#"C4 UID STORE 42 +FLAGS.SILENT (\Seen)"#, "C4 OK\r\n")
    ] + snapshot(5, unread: false) + [
        Exchange("C8 UID FETCH 42 (UID RFC822.SIZE)", "* 1 FETCH (UID 42 RFC822.SIZE 4)\r\nC8 OK\r\n"),
        Exchange("C9 UID FETCH 42 (UID BODY.PEEK[])", "")
    ])
    let workspace = MailTranscript(handshake("MOVE", account: second, wirePassword: appPassword) + [
        Exchange(#"C4 LIST "" "*""#, #"* LIST (\Trash) "/" "[Gmail]/Papelera""# + "\r\nC4 OK listed\r\n")
    ] + snapshot(5, unread: true) + [
        Exchange("C8 UID SEARCH UNSEEN", "* SEARCH 42\r\nC8 OK\r\n"),
        Exchange(#"C9 UID STORE 42 +FLAGS.SILENT (\Seen)"#, "C9 OK\r\n")
    ] + snapshot(10, unread: false) + [
        Exchange(#"C13 LIST "" "*""#, #"* LIST (\Trash) "/" "[Gmail]/Papelera""# + "\r\nC13 OK\r\n"),
        Exchange(#"C14 UID MOVE 42 "[Gmail]/Papelera""#, "* 1 EXPUNGE\r\nC14 OK\r\n"),
        Exchange("C15 NOOP", "C15 OK\r\n"),
        Exchange("C16 UID SEARCH UNSEEN", "* SEARCH\r\nC16 OK\r\n")
    ])
    var streams = [MailTranscript(handshake("", account: first, wirePassword: appPassword)), lost,
                   MailTranscript(handshake("", account: second, wirePassword: appPassword)), workspace, restored][...]
    var credentialWrites: [String: Bool] = [:]
    let service = MailService(accountsURL: url, makeConnection: { provider in
        MailIMAP(socket: streams.popFirst() ?? MailTranscript([]), provider: provider)
    }, readCredential: { _ in appPassword }, writeCredential: { password, account in
        credentialWrites[account] = password != nil
    })
    defer { service.stop() }
    let streamCount = streams.count
    do {
        try await service.addAccount(email: first, label: "A", appPassword: "MyGmailPass123!?")
        expect("Invalid app password is rejected before opening IMAP", false)
    } catch {
        expect("Invalid app password is rejected before opening IMAP",
               (error as? MailFailure) == .invalidAppPassword && streams.count == streamCount)
    }
    try await service.addAccount(email: first, label: "A", appPassword: "Abcd Efgh Ijkl Mnop")
    service.start()
    try await waitUntil { lost.isWaiting && service.messages.count == 1 }
    service.refresh()
    try await waitUntil { lost.isWaiting && service.unreadCount == 1 }
    expect("Wake refresh reconciles server-side changes", service.messages.first?.unread == true)
    try await service.addAccount(email: second, label: "B", appPassword: appPassword)
    try await waitUntil { workspace.isWaiting && service.unreadCount == 2 }
    expect("Two accounts retain independent UIDs, totals and labels",
           service.messages.count == 2 && service.unread(for: first) == 1 && service.unread(for: second) == 1)
    guard let message = service.messages.first(where: { $0.accountID == first }),
          let other = service.messages.first(where: { $0.accountID == second }) else { throw MailIMAPError.invalidResponse }
    expect("Archive is hidden without MOVE/UIDPLUS or a visible Gmail All Mail folder",
           !service.canArchive(message) && !service.canArchive(other))
    service.markRead(message)
    try await waitUntil { lost.isClosed }
    expect("An unacknowledged STORE leaves the count intact", service.unreadCount == 2)
    try await waitUntil { restored.isWaiting && service.unreadCount == 1 }
    expect("Reconnect retries Seen and updates only that account", service.unread(for: first) == 0 && service.unread(for: second) == 1)
    service.markAllRead(accountID: second)
    try await waitUntil { service.unreadCount == 0 && workspace.isWaiting }
    expect("Mark all reconciles rows and both chips", service.messages.allSatisfy { !$0.unread } && service.unread(for: second) == 0)
    service.trash(other)
    try await waitUntil { service.messages.count == 1 && workspace.isWaiting }
    expect("Trash removes the selected row and keeps counts consistent", service.messages.first?.accountID == first && service.unreadCount == 0)

    let pendingBody = Task { try await service.content(of: message) }
    try await waitUntil { restored.isWaitingForReply }
    guard var account = service.accounts.first(where: { $0.id == first }) else { throw MailIMAPError.invalidResponse }
    account.enabled = false
    service.updateAccount(account)
    do {
        _ = try await pendingBody.value
        expect("Disable cancels pending body", false)
    } catch {
        expect("Disable cancels pending body and clears cached rows", restored.isClosed && service.messages.isEmpty && service.status[first] == .paused)
    }
    service.removeAccount(second)
    let persisted = try JSONDecoder().decode([MailAccount].self, from: Data(contentsOf: url))
    expect("Remove closes the worker and deletes its credential and metadata",
           workspace.isClosed && credentialWrites[first] == true && credentialWrites[second] == false && persisted == [account])
    let unfinished = MailTranscript([Exchange(#"C1 LOGIN "unit@gmail.com" "AbcdEfghIjklMnop""#, "")])
    let signingIn = MailService(accountsURL: url, makeConnection: { MailIMAP(socket: unfinished, provider: $0) },
                                readCredential: { _ in nil }, writeCredential: { _, _ in })
    let attempt = Task { try await signingIn.addAccount(email: first, label: "", appPassword: appPassword) }
    try await waitUntil { unfinished.isWaitingForReply }
    signingIn.removeAccount(first)
    do {
        try await attempt.value
        expect("Removed account cannot be re-added by old LOGIN", false)
    } catch {
        expect("Removing during sign-in closes LOGIN and preserves removal", unfinished.isClosed && signingIn.accounts.isEmpty)
    }
    let corrupt = wire("incomplete")
    try corrupt.write(to: url)
    let damaged = MailService(accountsURL: url, makeConnection: { MailIMAP(socket: MailTranscript([]), provider: $0) },
                              readCredential: { _ in nil }, writeCredential: { _, _ in expect("Unexpected credential write", false) })
    do {
        try await damaged.addAccount(email: first, label: "A", appPassword: appPassword)
        expect("Unreadable account file preserved", false)
    } catch {
        let saved = try Data(contentsOf: url)
        expect("Unreadable account file preserved", damaged.accountsLoadFailed && saved == corrupt)
    }
}
do { try await checkAccountLifecycle() } catch { expect("Account lifecycle transcript", false) }

/// Regression: after an update, sync waited for the Keychain explanation window; while it sat unnoticed the flyout said
/// "Inbox is empty" (status .paused, no rows). Waiting, paused and loading must never read as an empty inbox.
@MainActor
private func checkKeychainNoticeGate() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let url = temporary.appendingPathComponent("mail-accounts.json")
    let email = "unit@gmail.com", appPassword = "AbcdEfghIjklMnop"
    try JSONEncoder().encode([MailAccount(id: email, label: "A", colorIndex: 0, enabled: true, provider: .gmail)]).write(to: url)
    let suite = "cala-mail-check-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw MailIMAPError.invalidResponse }
    defer { defaults.removePersistentDomain(forName: suite) }
    let fields = "HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING CONTENT-DISPOSITION)"
    let stream = MailTranscript(handshake("", account: email, wirePassword: appPassword) + [
        Exchange("C4 NOOP", "C4 OK\r\n"),
        Exchange("C5 FETCH 1:* (UID INTERNALDATE BODY.PEEK[\(fields)] BODY.PEEK[TEXT]<0.16384>)",
                 "* 1 FETCH (UID 42 BODY[\(fields)] {2}\r\n\r\n BODY[TEXT]<0> {4}\r\nHola)\r\nC5 OK\r\n"),
        Exchange("C6 UID SEARCH UNSEEN", "* SEARCH 42\r\nC6 OK\r\n")
    ])
    var connections = 0
    let gate = MailKeychainGate(identity: "helper-2", defaults: defaults)
    let keychain = FakeKeychain([email: appPassword])   // only the old (pre-helper) item exists
    let store = MailCredentialStore(get: keychain.get, set: keychain.set, gate: gate)
    let service = MailService(accountsURL: url, makeConnection: { connections += 1; return MailIMAP(socket: stream, provider: $0) },
                              readCredential: { try store.read($0) }, writeCredential: { try store.write($0, $1) },
                              readCurrentCredential: { try store.readOwn($0) }, keychainGate: gate)
    defer { service.stop() }
    func phase() -> MailInboxPhase {
        MailInboxPhase.of(accounts: service.accounts.map(\.id), status: service.status, synced: service.syncedAccounts,
                          hasMessages: !service.messages.isEmpty, awaitingKeychainNotice: service.awaitingKeychainNotice)
    }
    var proceed: (@MainActor () -> Void)?
    service.start { prompts, next in
        expect("Keychain explanation announces up to two windows per account not yet in the helper's item", prompts == 2)
        proceed = next
    }
    expect("While the Keychain explanation is open, nothing is read and the flyout says it is waiting (not empty)",
           proceed != nil && connections == 0 && service.awaitingKeychainNotice && service.messages.isEmpty
           && phase() == .waitingForKeychainNotice)
    service.continueAfterKeychainNotice()   // the flyout's "continue" while the window is still open
    proceed?()                               // then the window closes: must not start twice
    expect("Continuing from the flyout starts sync once", !service.awaitingKeychainNotice)
    try await waitUntil { stream.isWaiting && service.messages.count == 1 }
    expect("After continuing, the inbox syncs, the password is copied into the helper's item and the account counts as moved",
           connections == 1 && service.unreadCount == 1 && phase() == .messages && gate.isMigrated(email)
           && keychain.items[MailCredentialStore.ownAccount(email)] == appPassword && keychain.items[email] == appPassword)
    var shownAgain = false
    service.stop()
    service.start { _, _ in shownAgain = true }
    expect("Once every enabled account is moved, the explanation is not shown again", !shownAgain && !service.awaitingKeychainNotice)

    let a = "a@example.test", b = "b@example.test"
    expect("Phase: connecting with no snapshot is loading, not empty",
           MailInboxPhase.of(accounts: [a], status: [a: .connecting], synced: [], hasMessages: false,
                             awaitingKeychainNotice: false) == .loading)
    expect("Phase: never started is paused, not empty",
           MailInboxPhase.of(accounts: [a], status: [a: .paused], synced: [], hasMessages: false,
                             awaitingKeychainNotice: false) == .paused)
    expect("Phase: a synced account with no rows is a real empty inbox",
           MailInboxPhase.of(accounts: [a], status: [a: .connected], synced: [a], hasMessages: false,
                             awaitingKeychainNotice: false) == .empty)
    expect("Phase: one synced and one still connecting is loading",
           MailInboxPhase.of(accounts: [a, b], status: [a: .connected, b: .connecting], synced: [a], hasMessages: false,
                             awaitingKeychainNotice: false) == .loading)
    expect("Phase: a failed sync shows the account problem, not an empty inbox",
           MailInboxPhase.of(accounts: [a], status: [a: MailFailure.keychainDenied.status], synced: [], hasMessages: false,
                             awaitingKeychainNotice: false) == .problem)
    expect("Keychain denial stops retrying (no prompt loop) and is shown as a sign-in problem",
           MailFailure.keychainDenied.requiresUserAction && MailFailure.keychainDenied.status.problem != nil)
    expect("Keychain helper refusal (Cala.app replaced while running) asks for a restart and stops retrying",
           MailFailure.keychainRestart.requiresUserAction
           && MailFailure.keychainRestart.status.problem == MailFailure.keychainRestart.localizedDescription
           && MailFailure.keychainRestart.localizedDescription != MailFailure.keychain.localizedDescription)
    expect("Keychain helper unable to verify its caller asks for action, stops retrying and says something distinct",
           MailFailure.keychainUnverified.requiresUserAction
           && MailFailure.keychainUnverified.status.problem == MailFailure.keychainUnverified.localizedDescription
           && Set([MailFailure.keychainUnverified, .keychainRestart, .keychain].map(\.localizedDescription)).count == 3)
}
do { try await checkKeychainNoticeGate() } catch { expect("Keychain notice gate transcript", false) }
checkCredentialMigration()

/// In-memory stand-in for the Keychain helper: account -> password, with counters and injectable failures.
final class FakeKeychain: @unchecked Sendable {
    var items: [String: String]
    var reads: [String: Int] = [:]
    var failRead: [String: MailFailure] = [:]
    var failWrite: [String: MailFailure] = [:]
    var onGet: ((String) -> Void)?
    init(_ items: [String: String] = [:]) { self.items = items }
    func get(_ account: String) throws -> String? {
        onGet?(account)
        reads[account, default: 0] += 1
        if let failure = failRead[account] { throw failure }
        return items[account]
    }
    func set(_ password: String?, _ account: String) throws {
        if let failure = failWrite[account] { throw failure }
        items[account] = password
    }
}

private func checkCredentialMigration() {
    typealias Store = MailCredentialStore
    typealias Gate = MailKeychainGate
    let trusted = MailItemAccess(exists: true, aclTrustsHelper: true, partitionTrustsHelper: true)
    let neither = MailItemAccess(exists: true, aclTrustsHelper: false, partitionTrustsHelper: false)
    let aclOnly = MailItemAccess(exists: true, aclTrustsHelper: true, partitionTrustsHelper: false)
    let unknownPartition = MailItemAccess(exists: true, aclTrustsHelper: true, partitionTrustsHelper: nil)
    let deniedUnknown = MailItemAccess(exists: true, aclTrustsHelper: false, partitionTrustsHelper: nil)
    expect("Prediction: an old item that already trusts the helper (access list and partition) shows no window",
           Gate.expectedWindows(migrated: false, own: .missing, old: trusted) == 0)
    expect("Prediction: one window per missing trust (access list, partition), two when neither trusts the helper",
           Gate.expectedWindows(migrated: false, own: .missing, old: aclOnly) == 1
           && Gate.expectedWindows(migrated: false, own: .missing, old: neither) == 2
           && Gate.expectedWindows(migrated: false, own: .missing, old: deniedUnknown) == 2)
    expect("Prediction: unknown parts with nothing known missing, or an item that could not be inspected, are unknown",
           Gate.expectedWindows(migrated: false, own: .missing, old: unknownPartition) == nil
           && Gate.expectedWindows(migrated: false, own: nil, old: nil) == nil
           && Gate.expectedWindows(migrated: false, own: .missing, old: nil) == nil)
    expect("Prediction: a moved account, no old item, or an existing helper item that trusts the helper show nothing",
           Gate.expectedWindows(migrated: true, own: nil, old: nil) == 0
           && Gate.expectedWindows(migrated: false, own: .missing, old: .missing) == 0
           && Gate.expectedWindows(migrated: false, own: trusted, old: neither) == 0)
    expect("Prediction: an existing helper item that does not trust this helper (it was replaced) is judged on its own",
           Gate.expectedWindows(migrated: false, own: neither, old: trusted) == 2)
    expect("Partition entries decode from their hex JSON (or property list); anything else is unknown",
           MailKeychainAccess.partitionIDs(Data(#"{"Partitions":["teamid:ABCD","cdhash:AA"]}"#.utf8)
                .map { String(format: "%02X", $0) }.joined()) == ["teamid:abcd", "cdhash:aa"]
           && MailKeychainAccess.partitionIDs(Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Partitions</key><array><string>teamid:ABCD</string><string>cdhash:AA</string></array></dict></plist>"#.utf8)
                .map { String(format: "%02x", $0) }.joined()) == ["teamid:abcd", "cdhash:aa"]
           && MailKeychainAccess.partitionIDs("zz") == nil)
    do {
        let suite = "cala-mail-plan-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            let items: [String: MailItemAccess] = ["silent@x.test": trusted, "asks@x.test": neither, "v2:fresh@x.test": trusted]
            let gate = Gate(identity: "helper-P", defaults: defaults, inspect: { items[$0] ?? .missing })
            gate.markMigrated("moved@x.test")
            let plan = gate.plan(for: ["silent@x.test", "asks@x.test", "fresh@x.test", "moved@x.test", "gone@x.test"])
            expect("Plan: only accounts whose read will show windows are announced up front; silent or new ones are watched",
                   plan == Gate.Plan(windows: 2, watch: ["silent@x.test", "fresh@x.test", "gone@x.test"]))
            let blind = Gate(identity: "helper-P", defaults: defaults, inspect: { _ in nil })
            expect("Plan: items that cannot be inspected are watched (explained only if the read waits), not announced",
                   blind.plan(for: ["asks@x.test"]) == Gate.Plan(windows: 0, watch: ["asks@x.test"]))
            expect("Plan: without an inspector every account not moved is announced as two windows",
                   Gate(identity: "helper-P", defaults: defaults).plan(for: ["asks@x.test", "moved@x.test"]) == Gate.Plan(windows: 2, watch: []))
        }
    }
    expect("Migration plan: own item found is used (moved or not); missing and not moved reads the old item and copies it",
           Store.next(after: .found, migrated: false) == .use && Store.next(after: .found, migrated: true) == .use
           && Store.next(after: .missing, migrated: false) == .readOldThenCopy)
    expect("Migration plan: a moved account whose own item vanished clears the flag and explains first (never reads the old item silently)",
           Store.next(after: .missing, migrated: true) == .forgetAndExplain)
    expect("Migration plan: a denied own item always fails (no old-item read); so does a refused helper",
           Store.next(after: .denied, migrated: false) == .fail && Store.next(after: .denied, migrated: true) == .fail
           && Store.next(after: .refused, migrated: false) == .fail && Store.next(after: .refused, migrated: true) == .fail)
    expect("Migration plan: a broken own item falls back to the old one only while not moved",
           Store.next(after: .broken, migrated: false) == .readOldOnly && Store.next(after: .broken, migrated: true) == .fail)
    expect("Account ids starting with \"v2:\" are reserved and rejected with their own message",
           Store.isReserved("v2:a@b.test") && Store.isReserved("V2:a@b.test") && !Store.isReserved("av2:a@b.test")
           && MailFailure.reservedEmail.localizedDescription != MailFailure.invalidEmail.localizedDescription)

    let suite = "cala-mail-migration-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { expect("migration defaults", false); return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = MailKeychainGate(identity: "helper-A", defaults: defaults)
    let old = "old@example.test", own = Store.ownAccount(old)
    let keychain = FakeKeychain([old: "secret"])
    let store = Store(get: keychain.get, set: keychain.set, gate: gate)
    expect("Migration: an account only in the old item expects up to two windows", gate.expectedPrompts(for: [old]) == 2)

    keychain.failWrite[own] = .keychain
    let first = try? store.read(old)
    expect("Migration: a failed copy still returns the password, keeps the old item and stays unmoved",
           first == "secret" && keychain.items[old] == "secret" && keychain.items[own] == nil && !gate.isMigrated(old))
    keychain.failWrite[own] = nil
    let second = try? store.read(old)
    expect("Migration: the next read retries the copy and marks the account moved",
           second == "secret" && keychain.items[own] == "secret" && gate.isMigrated(old) && gate.expectedPrompts(for: [old]) == 0)
    let oldReads = keychain.reads[old]
    let third = try? store.read(old)
    expect("Migration: once moved, only the helper's own item is read (the old item is not touched)",
           third == "secret" && keychain.reads[old] == oldReads)

    func failure(_ body: () throws -> Any?) -> MailFailure? {
        do { _ = try body(); return nil } catch { return error as? MailFailure }
    }
    keychain.failRead[own] = .keychainDenied
    expect("Migration: a denied own item is reported and the old item is not read",
           failure { try store.read(old) } == .keychainDenied && keychain.reads[old] == oldReads)
    keychain.failRead[own] = .keychain
    expect("Migration: a broken own item of a moved account fails without touching the old item",
           failure { try store.read(old) } == .keychain && keychain.reads[old] == oldReads)
    keychain.failRead[own] = .keychainRestart
    expect("Migration: a helper that refuses Cala is reported, without trying the old item",
           failure { try store.read(old) } == .keychainRestart && keychain.reads[old] == oldReads)
    keychain.failRead[own] = nil

    let broken = "broken@example.test"
    keychain.items[broken] = "legacy"
    keychain.failRead[Store.ownAccount(broken)] = .keychain
    expect("Migration: a broken own item of an account not moved yet falls back to the old item, copying nothing",
           (try? store.read(broken)) == "legacy" && keychain.items[Store.ownAccount(broken)] == nil && !gate.isMigrated(broken))
    keychain.failRead[Store.ownAccount(broken)] = nil

    keychain.items[own] = nil   // the person deleted the helper's item (or restored an old Keychain)
    let readsBefore = keychain.reads[old]
    expect("Migration: a moved account whose own item vanished asks for the explanation and forgets the flag",
           failure { try store.read(old) } == .keychainNeedsNotice && !gate.isMigrated(old) && keychain.reads[old] == readsBefore
           && gate.expectedPrompts(for: [old]) == 2)
    expect("Migration: after that explanation the next read copies from the old item again",
           (try? store.read(old)) == "secret" && keychain.items[own] == "secret" && gate.isMigrated(old))

    // Race: Settings changes or removes the account while macOS is asking about the old item.
    let racing = "race@example.test"
    keychain.items[racing] = "stale"
    var raced = Store(get: keychain.get, set: keychain.set, gate: gate, generations: store.generations)
    raced.afterOldRead = { id in try? store.write("newer", id) }
    let racedValue = try? raced.read(racing)
    expect("Migration race: a password written during the old-item read is kept; the stale copy is skipped",
           racedValue == "stale" && keychain.items[Store.ownAccount(racing)] == "newer" && gate.isMigrated(racing))
    let removed = "removed@example.test"
    keychain.items[removed] = "stale"
    raced.afterOldRead = { id in try? store.write(nil, id) }
    _ = try? raced.read(removed)
    expect("Migration race: an account removed during the old-item read is not recreated or marked moved",
           keychain.items[Store.ownAccount(removed)] == nil && !gate.isMigrated(removed))

    // Race: account A waits for the migration lock (another account's macOS window is open) and Settings saves A's
    // new password meanwhile. A must not read its old item and must not overwrite the new password.
    let waiting = "waiting@example.test"
    keychain.items[waiting] = "OLD-A"
    let reachedOwnItem = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    keychain.onGet = { account in if account == Store.ownAccount(waiting) { reachedOwnItem.signal() } }
    store.generations.migration.lock()           // "account B's dialog is open"
    nonisolated(unsafe) var waitingResult: String?
    Thread.detachNewThread {
        waitingResult = try? store.read(waiting)
        finished.signal()
    }
    reachedOwnItem.wait()
    keychain.onGet = nil
    Thread.sleep(forTimeInterval: 0.05)          // A is now blocked on the migration lock
    try? store.write("NEW-A", waiting)           // Settings saves while A waits
    store.generations.migration.unlock()         // B's dialog closes
    finished.wait()
    expect("Migration race: a password saved while the account waited for another migration wins; the old item is not read",
           waitingResult == "NEW-A" && keychain.items[Store.ownAccount(waiting)] == "NEW-A" && keychain.reads[waiting] == nil
           && gate.isMigrated(waiting))

    let fresh = "new@example.test"
    try? store.write("brand-new", fresh)
    expect("Migration: a new account is written to the helper's own item only and counts as moved",
           keychain.items[Store.ownAccount(fresh)] == "brand-new" && keychain.items[fresh] == nil
           && keychain.reads[fresh] == nil && gate.isMigrated(fresh) && (try? store.readOwn(fresh)) == "brand-new")
    try? store.write(nil, old)
    expect("Migration: removing an account deletes the helper's item, keeps the old one and clears the flag",
           keychain.items[own] == nil && keychain.items[old] == "secret" && !gate.isMigrated(old))
    expect("Migration: a different helper identity means the account must be moved again",
           !MailKeychainGate(identity: "helper-B", defaults: defaults).isMigrated(fresh))
}

await runFastMailChecks()

print("\(passes) PASS, \(failures) FAIL")
exit(failures == 0 ? 0 : 1)
