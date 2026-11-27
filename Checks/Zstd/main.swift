import Foundation
import CryptoKit

// Usage: cala-zstd <fixtures> [--generate <dir>] [--zstd <cli>]
// The fixtures were made by the zstd 1.5 CLI from the inputs `--generate` writes (see scripts/check-zstd.sh).

var assertions = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    assertions += 1
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
        exit(1)
    }
}

/// Deterministic inputs: JSONL that looks like a rollout (repeats, numbers, base64 runs), random bytes, zeros.
struct Generator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func text(_ count: Int) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var data = Data()
        var line = 0
        while data.count < count {
            line += 1
            let used = next() % 100
            var row = "{\"timestamp\":\(1_794_917_700 + line * 7),\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
            row += "\"rate_limits\":{\"primary\":{\"used_percent\":\(used),\"window_minutes\":10080,\"resets_at\":1795522500}}"
            if next() % 4 == 0 {
                row += ",\"image\":\""
                for _ in 0..<(200 + Int(next() % 3_000)) { row.append(Character(UnicodeScalar(alphabet[Int(next() % 64)]))) }
                row += "\""
            }
            row += "}}\n"
            data.append(contentsOf: row.utf8)
        }
        return data.prefix(count)
    }

    mutating func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }) }
}

func inputs() -> [String: Data] {
    var generator = Generator(state: 42)
    return ["text": generator.text(160_000), "random": generator.random(40_000), "zeros": Data(count: 400_000),
            "empty": Data(), "tiny": Data("{\"type\":\"token_count\"}\n".utf8)]
}

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func decode(_ data: Data, limits: ZstdReader.Limits = .init(), chunk: Int = 1 << 20) throws -> Data {
    let reader = ZstdReader(data: data, limits: limits)
    var output = Data()
    while true {
        let part = try reader.read(upTo: chunk)
        if part.isEmpty { return output }
        check(part.count <= chunk + 128 * 1_024, "a read returns at most one block past the request")
        output.append(part)
    }
}

func failure(_ data: Data, limits: ZstdReader.Limits = .init()) -> ZstdReader.Failure? {
    do { _ = try decode(data, limits: limits); return nil } catch let error as ZstdReader.Failure { return error } catch { return nil }
}

let arguments = CommandLine.arguments
let fixtures = URL(fileURLWithPath: arguments[1], isDirectory: true)
if arguments.count == 4, arguments[2] == "--generate" {
    for (name, data) in inputs() { try data.write(to: URL(fileURLWithPath: arguments[3]).appendingPathComponent(name)) }
    exit(0)
}

let sources = inputs()
// fixture → input it must decode to.
let expected = ["text-1": "text", "text-19": "text", "text-window-1k": "text", "text-no-check": "text",
                "random-3": "random", "zeros-3": "zeros", "empty-3": "empty", "tiny-3": "tiny"]
for (fixture, input) in expected.sorted(by: { $0.key < $1.key }) {
    let data = try Data(contentsOf: fixtures.appendingPathComponent(fixture + ".zst"))
    let decoded = try decode(data)
    check(decoded == sources[input]!, "\(fixture) decodes to its input")
    let blockwise = try decode(data, chunk: 1)
    check(blockwise == decoded, "\(fixture) decodes the same one block at a time")
    if !decoded.isEmpty {
        let truncated = data.prefix(data.count - 3)
        check(failure(truncated) != nil, "\(fixture) cut short is rejected, never returned as complete")
    }
}

// Several frames with a skippable frame between them decode back to back.
let one = try Data(contentsOf: fixtures.appendingPathComponent("tiny-3.zst"))
let two = try Data(contentsOf: fixtures.appendingPathComponent("random-3.zst"))
var skippable = Data([0x5A, 0x2A, 0x4D, 0x18, 5, 0, 0, 0, 1, 2, 3, 4, 5])
let joined = try decode(one + skippable + two)
check(joined == sources["tiny"]! + sources["random"]!, "frames and skippable frames concatenate")
skippable.removeLast()
check(failure(one + skippable) == .truncated, "a cut skippable frame is truncated")

// Damage is detected: checksum, magic, reserved bits, dictionaries, oversized windows, empty input.
var damaged = try Data(contentsOf: fixtures.appendingPathComponent("text-1.zst"))
damaged[damaged.count / 2] ^= 0x20
check(failure(damaged) != nil, "a flipped byte in a checksummed frame is rejected")
check(failure(Data([1, 2, 3, 4, 5, 6])) == .corrupt("magic"), "wrong magic is rejected")
check(failure(Data()) == .truncated, "an empty file is not a clean stream")
var dictionary = one
dictionary[4] |= 0x01
dictionary.insert(7, at: 6)
check(failure(dictionary) == .unsupported("dictionary"), "dictionary frames are refused")
var reserved = one
reserved[4] |= 0x08
check(failure(reserved) == .corrupt("reserved bit"), "the reserved header bit is rejected")
let wide = try Data(contentsOf: fixtures.appendingPathComponent("text-19.zst"))
var small = ZstdReader.Limits()
small.maxWindow = 64 * 1_024
if case .unsupported = failure(wide, limits: small) {} else { check(false, "a window above the memory cap is refused") }

// XXH64 reference values (seed 0).
for (text, value) in [("", 0xEF46_DB37_51D8_E999 as UInt64), ("a", 0xD24E_C4F1_A98C_6E5B), ("abc", 0x44BC_2CF5_AD77_0999),
                      ("Nobody inspects the spammish repetition", 0xFBCE_A83C_8A37_8BF1)] {
    var hash = XXH64()
    Data(text.utf8).withUnsafeBytes { hash.update($0) }
    check(hash.digest() == value, "XXH64 of \"\(text)\"")
}

// Optional: compare against the zstd CLI on fresh inputs and levels when it is installed.
if arguments.count == 4, arguments[2] == "--zstd" {
    let cli = arguments[3]
    var generator = Generator(state: 7)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("cala-zstd-\(getpid())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for round in 0..<12 {
        let size = Int(generator.next() % 600_000)
        let input = round % 3 == 2 ? generator.random(size) : generator.text(size)
        let level = [1, 3, 6, 12, 19, -5][round % 6]
        let source = work.appendingPathComponent("in-\(round)")
        try input.write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-q", "-f", "--fast=5"].prefix(level < 0 ? 3 : 2) + (level < 0 ? [] : ["-\(level)"])
            + (round % 2 == 0 ? ["--no-check"] : []) + [source.path, "-o", source.path + ".zst"]
        try process.run()
        process.waitUntilExit()
        check(process.terminationStatus == 0, "zstd CLI compresses round \(round)")
        let decoded = try decode(Data(contentsOf: URL(fileURLWithPath: source.path + ".zst")))
        check(sha(decoded) == sha(input), "round \(round): \(size) bytes at level \(level) match the CLI")
    }
}
print("Zstd checks passed (\(assertions) assertions).")
