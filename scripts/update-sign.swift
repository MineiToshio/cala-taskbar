#!/usr/bin/env swift
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

private let domain = Data("cala-update-manifest-v1\n".utf8)
private let keyFormat = "cala-update-key-v1"
private let rounds: UInt32 = 600_000
private let feedLimit = 64 * 1024
private typealias PrivateKey = Curve25519.Signing.PrivateKey

private let wrongPassphraseMessage = "Unable to decrypt update key. Check the passphrase and key file."

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct EncryptedKey: Codable {
    var format = keyFormat
    var kdf = "pbkdf2-sha256"
    var iterations = rounds
    var salt: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    var publicKey: Data

    var aad: Data { Data("\(format)|\(iterations)|\(salt.base64EncodedString())|\(publicKey.base64EncodedString())".utf8) }

    init(key: PrivateKey, passphrase: Data) throws {
        salt = try randomBytes(16)
        nonce = try randomBytes(12)
        publicKey = key.publicKey.rawRepresentation
        ciphertext = Data()
        tag = Data()
        let sealed = try AES.GCM.seal(key.rawRepresentation, using: derive(passphrase, salt: salt),
                                      nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        ciphertext = sealed.ciphertext
        tag = sealed.tag
    }

    func unlock(_ passphrase: Data) throws -> PrivateKey {
        guard format == keyFormat, kdf == "pbkdf2-sha256", iterations == rounds,
              salt.count == 16, nonce.count == 12, ciphertext.count == 32, tag.count == 16, publicKey.count == 32 else {
            throw Failure("Invalid encrypted update key")
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        let raw: Data
        do {
            raw = try AES.GCM.open(box, using: derive(passphrase, salt: salt), authenticating: aad)
        } catch {
            throw Failure(wrongPassphraseMessage)
        }
        let key = try PrivateKey(rawRepresentation: raw)
        guard key.publicKey.rawRepresentation == publicKey else { throw Failure("Update key does not match its public key") }
        return key
    }
}

private struct TestKey: Codable {
    var format = "cala-update-testkey-v1"
    let privateKey: Data
    let publicKey: Data
}

private struct Envelope: Codable {
    let manifest: Data
    let signature: Data
}

private struct ManifestAsset: Decodable {
    struct DMG: Decodable {
        let size: UInt64
        let sha256: String
    }
    let dmg: DMG
}

private struct ReleaseManifest: Decodable {
    struct DMG: Decodable { let url: String }
    struct App: Decodable { let keychainHelperSHA256: String }
    let schema: Int
    let commit: String
    let bundleId: String
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let dmg: DMG
    let app: App

    static func decode(_ data: Data) throws -> Self {
        guard let manifest = try? JSONDecoder().decode(Self.self, from: data), manifest.schema == 1,
              manifest.commit.utf8.count == 40,
              manifest.commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure("Invalid schema 1 manifest. Expected release metadata and a full lowercase commit SHA.")
        }
        return manifest
    }
}

private func randomBytes(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw Failure("Could not get secure random bytes")
    }
    return Data(bytes)
}

private func derive(_ passphrase: Data, salt: Data) throws -> SymmetricKey {
    var key = [UInt8](repeating: 0, count: 32)
    let status = passphrase.withUnsafeBytes { password in
        salt.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: Int8.self).baseAddress, password.count,
                                 bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &key, 32)
        }
    }
    guard status == kCCSuccess else { throw Failure("Could not derive update encryption key") }
    return SymmetricKey(data: key)
}

private func readPassphrase(_ prompt: String) throws -> Data {
    var buffer = [CChar](repeating: 0, count: 4096)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil,
          let passphrase = String(validatingUTF8: buffer), passphrase.utf8.count < buffer.count - 1 else {
        throw Failure("Read the passphrase in your Terminal (12 or more characters)")
    }
    guard passphrase.count >= 12 else { throw Failure("Use a passphrase of at least 12 characters") }
    return Data(passphrase.utf8)
}

private func readPassphrase(from fd: Int32) throws -> Data {
    guard isatty(fd) == 0 else {
        throw Failure("The passphrase descriptor must be a pipe or file, not a terminal")
    }
    var passphrase = Data()
    var byte: UInt8 = 0
    // security -w can render each byte of a 4094-byte passphrase as two hex digits.
    while passphrase.count <= 8188 {
        let count = Darwin.read(fd, &byte, 1)
        if count < 0 && errno == EINTR { continue }
        if count == 0 || (count == 1 && byte == 0x0a) {
            if !passphrase.isEmpty { return passphrase }
            break
        }
        guard count == 1 else { break }
        passphrase.append(byte)
    }
    throw Failure("Could not read a passphrase from the file descriptor")
}

private func decodeSecurityHex(_ data: Data) -> Data? {
    guard data.count.isMultiple(of: 2) else { return nil }
    func digit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        default: return nil
        }
    }
    var decoded = Data()
    for index in stride(from: data.startIndex, to: data.endIndex, by: 2) {
        guard let high = digit(data[index]), let low = digit(data[index + 1]) else { return nil }
        decoded.append(high << 4 | low)
    }
    // Printable ASCII is emitted as-is by security, even when it looks like hex.
    return decoded.contains { !(32...126).contains($0) } ? decoded : nil
}

private func unlockFromDescriptor(_ encrypted: EncryptedKey, fd: Int32) throws -> PrivateKey {
    let passphrase = try readPassphrase(from: fd)
    do {
        return try encrypted.unlock(passphrase)
    } catch let failure as Failure where failure.errorDescription == wrongPassphraseMessage {
        guard let decoded = decodeSecurityHex(passphrase) else { throw failure }
        return try encrypted.unlock(decoded)
    }
}

private func passphraseDescriptor(_ argument: String) throws -> Int32 {
    guard let fd = Int32(argument), fd >= 0 else {
        throw Failure("Expected a nonnegative file descriptor for --passphrase-fd")
    }
    return fd
}

private func exclusiveWrite(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure("Could not create \(url.path): \(String(cString: strerror(errno)))") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

private func generate(_ out: URL) throws {
    let fm = FileManager.default
    var info = stat()
    guard lstat(out.path, &info) != 0, errno == ENOENT else {
        throw Failure("Refusing to overwrite \(out.path)")
    }
    let config = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/cala", isDirectory: true)
    if out.deletingLastPathComponent().standardizedFileURL.path == config.path {
        try fm.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard lstat(config.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw Failure("Expected a directory owned by you at \(config.path)")
        }
        guard chmod(config.path, 0o700) == 0 else { throw Failure("Could not set update key directory permissions") }
    }

    let passphrase = try readPassphrase("Nueva frase para la clave de firma de Cala / New Cala signing-key passphrase: ")
    guard try readPassphrase("Repite la frase / Repeat passphrase: ") == passphrase else { throw Failure("Passphrases do not match") }
    let encrypted = try EncryptedKey(key: PrivateKey(), passphrase: passphrase)
    try exclusiveWrite(JSONEncoder().encode(encrypted), to: out)
    print("Public key: \(encrypted.publicKey.base64EncodedString())")
    print("Add this line to packaging/update-public-keys:")
    print(encrypted.publicKey.base64EncodedString())
    print("Save the encrypted file and its passphrase in your password manager.")
}

private func loadKey(_ url: URL, passphraseFD: Int32?) throws -> PrivateKey {
    let data = try Data(contentsOf: url)
    #if CALA_UPDATE_TEST
    if let test = try? JSONDecoder().decode(TestKey.self, from: data), test.format == "cala-update-testkey-v1" {
        let key = try PrivateKey(rawRepresentation: test.privateKey)
        guard key.publicKey.rawRepresentation == test.publicKey else { throw Failure("Invalid test update key") }
        return key
    }
    #endif
    let encrypted = try JSONDecoder().decode(EncryptedKey.self, from: data)
    if let passphraseFD, let key = try? unlockFromDescriptor(encrypted, fd: passphraseFD) {
        return key
    }
    let prompt = "Frase de la clave de firma de Cala (\(url.lastPathComponent)) — NO es la contraseña del Mac / Cala signing-key passphrase, not your Mac password: "
    let attempts = 3
    for attempt in 1...attempts {
        do {
            return try encrypted.unlock(readPassphrase(prompt))
        } catch let failure as Failure where failure.errorDescription == wrongPassphraseMessage && attempt < attempts {
            FileHandle.standardError.write(Data("Frase incorrecta, intenta de nuevo (\(attempt)/\(attempts)) / Wrong passphrase, try again\n".utf8))
        }
    }
    throw Failure(wrongPassphraseMessage)
}

private func sign(_ manifest: Data, with key: PrivateKey) throws -> Data {
    let envelope = Envelope(manifest: manifest, signature: try key.signature(for: domain + manifest))
    let feed = try JSONEncoder().encode(envelope)
    guard feed.count <= feedLimit else { throw Failure("Signed feed exceeds 64 KB") }
    return feed
}

private func verify(_ feed: Data, publicKeys: [Data]) throws -> Data {
    guard feed.count <= feedLimit,
          let object = try JSONSerialization.jsonObject(with: feed) as? [String: Any],
          Set(object.keys) == ["manifest", "signature"] else { throw Failure("Invalid update envelope") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: feed)
    let message = domain + envelope.manifest
    for raw in publicKeys {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        if key.isValidSignature(envelope.signature, for: message) { return envelope.manifest }
    }
    throw Failure("Update signature does not match any trusted key")
}

private func verifyAsset(_ url: URL, manifest: Data) throws {
    let asset = try JSONDecoder().decode(ManifestAsset.self, from: manifest).dmg
    guard (1...200_000_000).contains(asset.size) else { throw Failure("DMG exceeds the update size limits") }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    var size: UInt64 = 0
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        size += UInt64(chunk.count)
        guard size <= asset.size else { throw Failure("DMG size differs from the manifest") }
        hash.update(data: chunk)
    }
    guard size == asset.size else { throw Failure("DMG size differs from the manifest") }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256.lowercased() else {
        throw Failure("DMG SHA-256 differs from the manifest")
    }
}

private func verifiedManifest(keys: URL, feed: URL, dmg: URL?) throws -> (Data, [Data]) {
    let keys = try String(contentsOf: keys, encoding: .utf8).split(whereSeparator: \.isWhitespace)
    guard (1...2).contains(keys.count) else { throw Failure("Expected one or two update public keys") }
    let publicKeys = try keys.map { text in
        guard let raw = Data(base64Encoded: String(text)), raw.count == 32 else { throw Failure("Invalid update public key") }
        return raw
    }
    let manifest = try verify(Data(contentsOf: feed), publicKeys: publicKeys)
    if let dmg { try verifyAsset(dmg, manifest: manifest) }
    return (manifest, publicKeys)
}

private func verifyRelease(keys: URL, feed: URL, dmg: URL, app: URL, tag: String, commit: String) throws {
    let (manifestBytes, publicKeys) = try verifiedManifest(keys: keys, feed: feed, dmg: dmg)
    let manifest = try ReleaseManifest.decode(manifestBytes)
    guard manifest.commit == commit else {
        throw Failure("Signed manifest commit differs from the commit for release tag \(tag)")
    }
    guard manifest.build > 0,
          manifest.version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
          tag == "v\(manifest.version)" else {
        throw Failure("Manifest version or build is invalid for release tag \(tag)")
    }
    let releases = "https://github.com/MineiToshio/cala-taskbar/releases"
    let name = "Cala-\(manifest.version).dmg"
    guard dmg.lastPathComponent == name, manifest.dmg.url == "\(releases)/download/\(tag)/\(name)" else {
        throw Failure("Manifest DMG URL or filename differs from the release asset")
    }
    let contents = app.appendingPathComponent("Contents")
    let helpers = contents.appendingPathComponent("Helpers")
    let plistURL = contents.appendingPathComponent("Info.plist")
    let helperURL = helpers.appendingPathComponent("cala-keychain")
    let fm = FileManager.default
    for url in [app, contents, helpers, plistURL, helperURL] {
        let expected: FileAttributeType = [plistURL, helperURL].contains(url) ? .typeRegular : .typeDirectory
        guard (try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == expected else {
            throw Failure("Unexpected file type in release DMG: \(url.lastPathComponent)")
        }
    }
    let plist = try Data(contentsOf: plistURL)
    guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
        throw Failure("Invalid Info.plist in the DMG")
    }
    guard !info.keys.contains(where: { $0.hasPrefix("CalaUpdateTest") || $0 == "CalaQARegular" }) else {
        throw Failure("Release DMG contains test settings")
    }
    let expected = [
        "CalaUpdateFeedURL": "\(releases)/latest/download/latest.json",
        "CFBundleIdentifier": manifest.bundleId,
        "CFBundleShortVersionString": manifest.version,
        "CFBundleVersion": String(manifest.build),
        "LSMinimumSystemVersion": manifest.minimumSystemVersion,
    ]
    for (key, value) in expected where (info[key] as? String) != value {
        throw Failure("Unexpected \(key) in the release DMG")
    }
    guard (info["CalaUpdatePublicKeys"] as? [String]) == publicKeys.map({ $0.base64EncodedString() }) else {
        throw Failure("Release DMG public keys differ from the committed keys")
    }
    let helper = try Data(contentsOf: helperURL)
    let hash = SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined()
    guard hash == manifest.app.keychainHelperSHA256 else {
        throw Failure("Keychain helper SHA-256 differs from the manifest")
    }
    print("PASS release signature, DMG, tag commit and bundled Info.plist")
}

private func makeTestKey(_ directory: URL) throws {
    let key = PrivateKey()
    let pair = TestKey(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try exclusiveWrite(JSONEncoder().encode(pair), to: directory.appendingPathComponent("private.json"))
    try exclusiveWrite(Data((pair.publicKey.base64EncodedString() + "\n").utf8), to: directory.appendingPathComponent("public"))
}

private func expectFailure(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure("Selftest accepted \(message)")
}

private func selftest() throws {
    let key = PrivateKey()
    let publicKey = key.publicKey.rawRepresentation
    let passphrase = Data("frase desechable de verificación ".utf8)
    let encrypted = try EncryptedKey(key: key, passphrase: passphrase)
    let decoded = try JSONDecoder().decode(EncryptedKey.self, from: JSONEncoder().encode(encrypted))
    let pipe = Pipe()
    let securityHex = passphrase.map { String(format: "%02x", $0) }.joined()
    try pipe.fileHandleForWriting.write(contentsOf: passphrase + Data("\nsecond line\n\(securityHex)\n".utf8))
    try pipe.fileHandleForWriting.close()
    let fd = pipe.fileHandleForReading.fileDescriptor
    let unlocked = try unlockFromDescriptor(decoded, fd: fd)
    guard try readPassphrase(from: fd) == Data("second line".utf8) else {
        throw Failure("Passphrase reader did not stop at the first newline")
    }
    guard try unlockFromDescriptor(decoded, fd: fd).rawRepresentation == key.rawRepresentation else {
        throw Failure("Passphrase reader did not handle security's hex output")
    }
    try expectFailure("an empty passphrase descriptor") { _ = try readPassphrase(from: fd) }
    let manifest = Data(#"{"schema":1}"#.utf8)
    let feed = try sign(manifest, with: unlocked)
    guard unlocked.rawRepresentation == key.rawRepresentation,
          try verify(feed, publicKeys: [publicKey]) == manifest else { throw Failure("Selftest round-trip failed") }
    let envelope = try JSONDecoder().decode(Envelope.self, from: feed)
    var flipped = manifest
    flipped[0] ^= 1
    let tampered = try JSONEncoder().encode(Envelope(manifest: flipped, signature: envelope.signature))
    try expectFailure("a flipped byte") { _ = try verify(tampered, publicKeys: [publicKey]) }
    try expectFailure("the wrong passphrase") { _ = try decoded.unlock(Data("incorrect passphrase".utf8)) }
    var changed = decoded
    changed.publicKey = PrivateKey().publicKey.rawRepresentation
    try expectFailure("changed AAD") { _ = try changed.unlock(passphrase) }
    print("PASS update-sign selftest")
}

private func run(_ args: [String]) throws {
    func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    switch args.first {
    case "generate" where args.count == 3 && args[1] == "--out":
        try generate(url(args[2]))
    case "sign" where (args.count == 7 || (args.count == 9 && args[7] == "--passphrase-fd"))
                        && args[1] == "--key" && args[3] == "--manifest" && args[5] == "--out":
        let manifest = try Data(contentsOf: url(args[4]))
        _ = try ReleaseManifest.decode(manifest)
        let fd = args.count == 9 ? try passphraseDescriptor(args[8]) : nil
        try sign(manifest, with: loadKey(url(args[2]), passphraseFD: fd)).write(to: url(args[6]), options: .atomic)
    case "check-key" where args.count == 5 && args[1] == "--key" && args[3] == "--passphrase-fd":
        do {
            let fd = try passphraseDescriptor(args[4])
            let encrypted = try JSONDecoder().decode(EncryptedKey.self, from: Data(contentsOf: url(args[2])))
            _ = try unlockFromDescriptor(encrypted, fd: fd)
            print("PASS signing key unlock")
        } catch {
            throw Failure("FAIL signing key unlock: \(error.localizedDescription)")
        }
    case "verify" where (args.count == 5 || (args.count == 7 && args[5] == "--dmg"))
                        && args[1] == "--keys" && args[3] == "--feed":
        _ = try verifiedManifest(keys: url(args[2]), feed: url(args[4]), dmg: args.count == 7 ? url(args[6]) : nil)
        print("PASS update signature" + (args.count == 7 ? " and DMG" : ""))
    case "verify-release" where args.count == 13 && args[1] == "--keys" && args[3] == "--feed"
                                && args[5] == "--dmg" && args[7] == "--app" && args[9] == "--tag" && args[11] == "--commit":
        try verifyRelease(keys: url(args[2]), feed: url(args[4]), dmg: url(args[6]), app: url(args[8]), tag: args[10], commit: args[12])
    case "testkey" where args.count == 2:
        try makeTestKey(url(args[1]))
    case "selftest" where args.count == 1:
        try selftest()
    default:
        throw Failure("""
        Usage: update-sign.swift generate --out FILE
               update-sign.swift sign --key FILE --manifest M --out FEED [--passphrase-fd FD]
               update-sign.swift check-key --key FILE --passphrase-fd FD
               update-sign.swift verify --keys KEYS --feed FEED [--dmg D]
               update-sign.swift verify-release --keys KEYS --feed FEED --dmg D --app APP --tag TAG --commit SHA
               update-sign.swift testkey DIR
               update-sign.swift selftest
        """)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("update-sign: \(error.localizedDescription)\n", stderr)
    exit(1)
}
