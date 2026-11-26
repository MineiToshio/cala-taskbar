import Foundation
import CryptoKit

enum UpdateSignature {
    static let domain = Data("cala-update-manifest-v1\n".utf8)
    enum Invalid: Error { case envelope, signature }

    static func verify(feed: Data, publicKeys: [Data]) throws -> (manifest: UpdateManifest, bytes: Data) {
        guard feed.count <= UpdateFeed.limit else { throw FeedFailure.tooLarge }
        guard let fields = try JSONSerialization.jsonObject(with: feed) as? [String: String],
              Set(fields.keys) == ["manifest", "signature"],
              // The two values are base64 strings. Count separators outside strings as
              // JSON dictionaries otherwise silently collapse duplicate member names.
              separators(in: feed) == 2,
              let bytes = Data(base64Encoded: fields["manifest"]!),
              let signature = Data(base64Encoded: fields["signature"]!) else { throw Invalid.envelope }
        let message = domain + bytes
        guard publicKeys.prefix(2).contains(where: { accepts(signature, message: message, publicKey: $0) })
        else { throw Invalid.signature }
        return (try UpdateManifest.decodeSigned(bytes), bytes)
    }

    private static func separators(in data: Data) -> Int {
        var quoted = false, escaped = false, count = 0
        for byte in data {
            if escaped { escaped = false }
            else if quoted && byte == 92 { escaped = true }
            else if byte == 34 { quoted.toggle() }
            else if !quoted && byte == 58 { count += 1 }
        }
        return count
    }

    static func accepts(_ signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    // Hash a bounded stream; optionally write exactly those bytes to a private image for mounting.
    static func hash(_ file: FileHandle, limit: Int64, copyingTo output: FileHandle? = nil) throws -> (Int64, String) {
        var digest = SHA256()
        var size: Int64 = 0
        while let bytes = try file.read(upToCount: 256 * 1024), !bytes.isEmpty {
            size += Int64(bytes.count)
            guard size <= limit else { throw FeedFailure.tooLarge }
            digest.update(data: bytes)
            try output?.write(contentsOf: bytes)
        }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
