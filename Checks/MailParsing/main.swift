import Foundation

/// The app writes this to its debug log; the checks have no log file.
func log(_ s: String) {}

var passes = 0
var failures = 0

func expect(_ name: String, _ condition: Bool) {
    if condition {
        passes += 1
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
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
    init(_ items: [String: String] = [:]) { self.items = items }
    func get(_ account: String) throws -> String? {
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
    expect("Migration plan: own item found is used; missing reads the old item and copies it",
           Store.next(after: .found) == .use && Store.next(after: .missing) == .readOldThenCopy)
    expect("Migration plan: an unreadable own item falls back to the old one without copying; a refused helper fails",
           Store.next(after: .unreadable) == .readOldOnly && Store.next(after: .refused) == .fail)

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

    keychain.failRead[own] = .keychainDenied
    let denied = try? store.read(old)
    expect("Migration: an own item that cannot be read falls back to the old item, copying nothing",
           denied == "secret" && keychain.reads[old] == (oldReads ?? 0) + 1)
    keychain.failRead[own] = .keychainRestart
    var refused: MailFailure?
    do { _ = try store.read(old) } catch { refused = error as? MailFailure }
    expect("Migration: a helper that refuses Cala is reported, without trying the old item",
           refused == .keychainRestart && keychain.reads[old] == (oldReads ?? 0) + 1)
    keychain.failRead[own] = nil

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

print("\(passes) PASS, \(failures) FAIL")
exit(failures == 0 ? 0 : 1)
