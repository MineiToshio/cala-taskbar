import Foundation

/// Decode-only, streaming Zstandard reader (RFC 8878), written for Cala so no third-party code is vendored.
///
/// Scope is deliberately small: plain frames and skippable frames, no dictionaries. Memory is bounded by the frame's
/// window (refused above `Limits.maxWindow`) plus one 128 KiB block; input is pulled in small chunks and output is
/// handed back a block at a time, so a 150 MB rollout never sits in memory whole. Any malformed, truncated or
/// unsupported input throws instead of guessing, and the optional content checksum (XXH64) is verified.
final class ZstdReader {
    enum Failure: Error, Equatable {
        case truncated
        case corrupt(String)
        case unsupported(String)
    }

    struct Limits {
        /// Largest frame window accepted. Codex writes 2 MiB windows; `zstd -19` uses 8 MiB.
        var maxWindow = 16 << 20
        var inputChunk = 256 * 1_024
    }

    private enum Stage { case frame, block, checksum, done }

    private static let blockMax = 128 * 1_024
    private static let padding = 16

    private let source: (Int) throws -> Data
    private let limits: Limits
    private var input = [UInt8]()
    private var inputPos = 0
    private var eof = false
    private(set) var compressedBytes = 0
    private(set) var frames = 0
    private var stage = Stage.frame
    private var failure: Error?

    // Frame state.
    private var windowSize = 0
    private var blockLimit = blockMax
    private var contentSize: UInt64?
    private var produced: UInt64 = 0
    private var hasChecksum = false
    private var hash = XXH64()
    private var reps = (1, 4, 8)
    private var huffman: HuffmanTable?
    private var llTable: FSETable?
    private var ofTable: FSETable?
    private var mlTable: FSETable?

    // Buffers.
    private var out: UnsafeMutablePointer<UInt8>?
    private var outCapacity = 0
    private var outPos = 0
    private let block = UnsafeMutablePointer<UInt8>.allocate(capacity: blockMax + padding)
    private let literals = UnsafeMutablePointer<UInt8>.allocate(capacity: blockMax + padding)

    init(limits: Limits = Limits(), source: @escaping (Int) throws -> Data) {
        self.limits = limits
        self.source = source
        block.initialize(repeating: 0, count: Self.blockMax + Self.padding)
        literals.initialize(repeating: 0, count: Self.blockMax + Self.padding)
    }

    convenience init(handle: FileHandle, limits: Limits = Limits()) {
        self.init(limits: limits) { count in try handle.read(upToCount: count) ?? Data() }
    }

    convenience init(data: Data, limits: Limits = Limits()) {
        var offset = 0
        self.init(limits: limits) { count in
            let end = min(data.count, offset + count)
            defer { offset = end }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + end)
        }
    }

    deinit {
        block.deallocate()
        literals.deallocate()
        out?.deallocate()
    }

    /// Returns at least one decoded block (roughly `limit` bytes, never more than `limit + 128 KiB`), or empty data
    /// once the input ended cleanly after a whole frame.
    func read(upTo limit: Int) throws -> Data {
        if let failure { throw failure }
        var result = Data()
        do {
            try fill(&result, limit: limit)
        } catch {
            // Hand back what was decoded before the damage; the next read reports it.
            guard !result.isEmpty else { throw error }
            failure = error
        }
        return result
    }

    private func fill(_ result: inout Data, limit: Int) throws {
        while result.count < max(1, limit) {
            switch stage {
            case .done:
                return
            case .frame:
                try startFrame()
            case .block:
                let start = try decodeBlock()
                let count = outPos - start
                if count > 0, let out {
                    let fresh = UnsafeBufferPointer(start: out + start, count: count)
                    if hasChecksum { hash.update(UnsafeRawBufferPointer(fresh)) }
                    result.append(fresh)
                }
            case .checksum:
                guard try need(4) else { throw Failure.truncated }
                let stored = UInt32(input[inputPos]) | UInt32(input[inputPos + 1]) << 8
                    | UInt32(input[inputPos + 2]) << 16 | UInt32(input[inputPos + 3]) << 24
                inputPos += 4
                guard stored == UInt32(truncatingIfNeeded: hash.digest()) else { throw Failure.corrupt("checksum") }
                stage = .frame
            }
        }
    }

    /// Decodes the whole stream into memory (tests and small inputs only).
    static func decompress(_ data: Data, limits: Limits = Limits()) throws -> Data {
        let reader = ZstdReader(data: data, limits: limits)
        var result = Data()
        while true {
            let chunk = try reader.read(upTo: 1 << 20)
            if chunk.isEmpty { return result }
            result.append(chunk)
        }
    }

    // MARK: Input

    private func need(_ count: Int) throws -> Bool {
        while input.count - inputPos < count {
            if eof { return false }
            if inputPos > 0 {
                input.removeSubrange(0..<inputPos)
                inputPos = 0
            }
            let chunk = try source(max(limits.inputChunk, count))
            if chunk.isEmpty { eof = true } else {
                compressedBytes += chunk.count
                input.append(contentsOf: chunk)
            }
        }
        return true
    }

    private func byte(_ offset: Int) -> Int { Int(input[inputPos + offset]) }

    private func littleEndian(_ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(input[inputPos + offset + index]) << (8 * index) }
        return value
    }

    // MARK: Frames

    private func startFrame() throws {
        guard try need(4) else {
            // A clean end only between frames, and only after at least one real frame.
            guard input.count == inputPos, frames > 0 else { throw Failure.truncated }
            stage = .done
            return
        }
        let magic = UInt32(littleEndian(0, 4))
        if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            guard try need(8) else { throw Failure.truncated }
            var skip = Int(littleEndian(4, 4))
            inputPos += 8
            while skip > 0 {
                guard try need(1) else { throw Failure.truncated }
                let step = min(skip, input.count - inputPos)
                inputPos += step
                skip -= step
            }
            return
        }
        guard magic == 0xFD2F_B528 else { throw Failure.corrupt("magic") }
        guard try need(5) else { throw Failure.truncated }
        let descriptor = byte(4)
        let fcsFlag = descriptor >> 6
        let single = descriptor & 0x20 != 0
        guard descriptor & 0x08 == 0 else { throw Failure.corrupt("reserved bit") }
        let dictBytes = [0, 1, 2, 4][descriptor & 3]
        let fcsBytes = [single ? 1 : 0, 2, 4, 8][fcsFlag]
        let headerBytes = 5 + (single ? 0 : 1) + dictBytes + fcsBytes
        guard try need(headerBytes) else { throw Failure.truncated }
        var offset = 5
        var window: UInt64 = 0
        if !single {
            let value = byte(offset)
            offset += 1
            let log = 10 + (value >> 3)
            let base = UInt64(1) << UInt64(log)
            window = base + (base / 8) * UInt64(value & 7)
        }
        if dictBytes > 0 {
            guard littleEndian(offset, dictBytes) == 0 else { throw Failure.unsupported("dictionary") }
            offset += dictBytes
        }
        contentSize = nil
        if fcsBytes > 0 {
            var size = littleEndian(offset, fcsBytes)
            if fcsBytes == 2 { size += 256 }
            contentSize = size
        }
        if single { window = contentSize ?? 0 }
        guard window <= UInt64(limits.maxWindow) else { throw Failure.unsupported("window \(window)") }
        inputPos += headerBytes
        windowSize = Int(window)
        blockLimit = min(Self.blockMax, max(windowSize, 1))
        hasChecksum = descriptor & 0x04 != 0
        hash = XXH64()
        produced = 0
        reps = (1, 4, 8)
        huffman = nil
        llTable = nil
        ofTable = nil
        mlTable = nil
        // The history keeps a whole window; it slides once per extra window (or MiB) of output.
        let capacity = windowSize + max(windowSize, 1 << 20) + Self.blockMax
        if capacity > outCapacity || capacity < outCapacity / 4 {
            out?.deallocate()
            out = .allocate(capacity: capacity)
            outCapacity = capacity
        }
        outPos = 0
        frames += 1
        stage = .block
    }

    /// Decodes one block and returns where its output starts in the history buffer.
    private func decodeBlock() throws -> Int {
        guard try need(3) else { throw Failure.truncated }
        let header = Int(littleEndian(0, 3))
        inputPos += 3
        let last = header & 1 != 0
        let type = (header >> 1) & 3
        let size = header >> 3
        guard let out else { throw Failure.corrupt("state") }
        if outPos + Self.blockMax > outCapacity {
            let keep = min(outPos, windowSize)
            memmove(out, out + (outPos - keep), keep)
            outPos = keep
        }
        let start = outPos
        switch type {
        case 0:
            guard size <= blockLimit else { throw Failure.corrupt("raw block size") }
            guard try need(size) else { throw Failure.truncated }
            input.withUnsafeBufferPointer { buffer in
                (out + outPos).update(from: buffer.baseAddress! + inputPos, count: size)
            }
            inputPos += size
            outPos += size
        case 1:
            guard size <= blockLimit else { throw Failure.corrupt("rle block size") }
            guard try need(1) else { throw Failure.truncated }
            (out + outPos).update(repeating: input[inputPos], count: size)
            inputPos += 1
            outPos += size
        case 2:
            guard size <= blockLimit, size > 0 else { throw Failure.corrupt("compressed block size") }
            guard try need(size) else { throw Failure.truncated }
            input.withUnsafeBufferPointer { buffer in
                block.update(from: buffer.baseAddress! + inputPos, count: size)
            }
            (block + size).update(repeating: 0, count: Self.padding)
            inputPos += size
            try decompressBlock(size)
        default:
            throw Failure.corrupt("reserved block type")
        }
        if type < 2 { produced += UInt64(size) }
        if last {
            if let contentSize, contentSize != produced { throw Failure.corrupt("content size") }
            stage = hasChecksum ? .checksum : .frame
        }
        return start
    }

    // MARK: Compressed blocks

    private func decompressBlock(_ size: Int) throws {
        let blockStart = outPos
        var position = 0
        let (literalCount, literalsUsed) = try decodeLiterals(size)
        position += literalsUsed
        guard position < size else { throw Failure.corrupt("sequences header") }
        var count = Int(block[position])
        position += 1
        if count >= 128 {
            guard position < size else { throw Failure.corrupt("sequences header") }
            if count < 255 {
                count = ((count - 128) << 8) + Int(block[position])
                position += 1
            } else {
                guard position + 1 < size else { throw Failure.corrupt("sequences header") }
                count = Int(block[position]) + (Int(block[position + 1]) << 8) + 0x7F00
                position += 2
            }
        }
        guard let out else { throw Failure.corrupt("state") }
        if count == 0 {
            guard position == size else { throw Failure.corrupt("trailing bytes") }
            guard literalCount <= blockLimit else { throw Failure.corrupt("block size") }
            (out + outPos).update(from: literals, count: literalCount)
            outPos += literalCount
            produced += UInt64(literalCount)
            return
        }
        guard position < size else { throw Failure.corrupt("sequences modes") }
        let modes = Int(block[position])
        position += 1
        guard modes & 3 == 0 else { throw Failure.corrupt("sequences reserved") }
        llTable = try table(mode: modes >> 6, kind: .literalLength, previous: llTable, at: &position, size: size)
        ofTable = try table(mode: (modes >> 4) & 3, kind: .offset, previous: ofTable, at: &position, size: size)
        mlTable = try table(mode: (modes >> 2) & 3, kind: .matchLength, previous: mlTable, at: &position, size: size)
        guard let ll = llTable, let of = ofTable, let ml = mlTable, position < size else {
            throw Failure.corrupt("sequences bitstream")
        }
        var bits = try BackwardBits(block + position, count: size - position)
        var llState = bits.read(ll.log)
        var ofState = bits.read(of.log)
        var mlState = bits.read(ml.log)
        var literalPos = 0
        var reps = self.reps
        let history = windowSize
        for index in 0..<count {
            let ofCode = Int(of.symbol[ofState])
            let mlCode = Int(ml.symbol[mlState])
            let llCode = Int(ll.symbol[llState])
            guard ofCode <= 31 else { throw Failure.corrupt("offset code") }
            let offsetValue = (1 << ofCode) + bits.read(ofCode)
            let matchLength = Self.matchBase[mlCode] + bits.read(Self.matchBits[mlCode])
            let literalLength = Self.literalBase[llCode] + bits.read(Self.literalBits[llCode])
            let offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                reps = (offset, reps.0, reps.1)
            } else {
                let repeatIndex = offsetValue - 1 + (literalLength == 0 ? 1 : 0)
                switch repeatIndex {
                case 0: offset = reps.0
                case 1: offset = reps.1; reps = (offset, reps.0, reps.2)
                case 2: offset = reps.2; reps = (offset, reps.0, reps.1)
                default: offset = max(reps.0 - 1, 1); reps = (offset, reps.0, reps.1)
                }
            }
            if index + 1 < count {
                llState = Int(ll.base[llState]) + bits.read(Int(ll.bits[llState]))
                mlState = Int(ml.base[mlState]) + bits.read(Int(ml.bits[mlState]))
                ofState = Int(of.base[ofState]) + bits.read(Int(of.bits[ofState]))
            }
            guard literalPos + literalLength <= literalCount,
                  outPos - blockStart + literalLength + matchLength <= blockLimit else {
                throw Failure.corrupt("sequence length")
            }
            (out + outPos).update(from: literals + literalPos, count: literalLength)
            literalPos += literalLength
            outPos += literalLength
            guard offset > 0, offset <= outPos, offset <= history else { throw Failure.corrupt("offset") }
            let destination = out + outPos
            let source = destination - offset
            if offset >= matchLength {
                destination.update(from: source, count: matchLength)
            } else {
                for step in 0..<matchLength { destination[step] = source[step] }
            }
            outPos += matchLength
        }
        guard bits.exhausted else { throw Failure.corrupt("sequences end") }
        self.reps = reps
        let tail = literalCount - literalPos
        guard outPos - blockStart + tail <= blockLimit else { throw Failure.corrupt("block size") }
        (out + outPos).update(from: literals + literalPos, count: tail)
        outPos += tail
        produced += UInt64(outPos - blockStart)
    }

    /// Fills `literals`; returns the regenerated size and the bytes the section used.
    private func decodeLiterals(_ size: Int) throws -> (Int, Int) {
        func at(_ index: Int) throws -> Int {
            guard index < size else { throw Failure.corrupt("literals header") }
            return Int(block[index])
        }
        let first = try at(0)
        let type = first & 3
        let format = (first >> 2) & 3
        if type < 2 {
            let regenerated: Int
            let header: Int
            switch format {
            case 1: regenerated = (first >> 4) + (try at(1) << 4); header = 2
            case 3: regenerated = (first >> 4) + (try at(1) << 4) + (try at(2) << 12); header = 3
            default: regenerated = first >> 3; header = 1
            }
            guard regenerated <= blockLimit else { throw Failure.corrupt("literals size") }
            if type == 0 {
                guard header + regenerated <= size else { throw Failure.corrupt("raw literals") }
                literals.update(from: block + header, count: regenerated)
                return (regenerated, header + regenerated)
            }
            literals.update(repeating: UInt8(try at(header)), count: regenerated)
            return (regenerated, header + 1)
        }
        let header = [3, 3, 4, 5][format]
        let width = [10, 10, 14, 18][format]
        var value = 0
        for index in 0..<header { value |= try at(index) << (8 * index) }
        let mask = (1 << width) - 1
        let regenerated = (value >> 4) & mask
        let compressed = (value >> (4 + width)) & mask
        guard regenerated <= blockLimit, header + compressed <= size, compressed > 0 else {
            throw Failure.corrupt("compressed literals size")
        }
        var start = block + header
        var remaining = compressed
        if type == 2 {
            let (table, used) = try HuffmanTable.read(start, count: remaining)
            huffman = table
            start += used
            remaining -= used
        }
        guard let table = huffman else { throw Failure.corrupt("treeless literals without a table") }
        if format == 0 {
            try table.decode([.init(base: start, count: remaining, output: literals, symbols: regenerated)])
        } else {
            guard remaining >= 6 else { throw Failure.corrupt("jump table") }
            let sizes = (0..<3).map { Int(start[2 * $0]) | Int(start[2 * $0 + 1]) << 8 }
            let fourth = remaining - 6 - sizes[0] - sizes[1] - sizes[2]
            let segment = (regenerated + 3) / 4
            let lastSegment = regenerated - 3 * segment
            guard fourth > 0, lastSegment >= 0 else { throw Failure.corrupt("jump table") }
            var stream = start + 6
            var streams: [HuffmanTable.Stream] = []
            for (index, streamSize) in (sizes + [fourth]).enumerated() {
                streams.append(.init(base: stream, count: streamSize, output: literals + index * segment,
                                     symbols: index == 3 ? lastSegment : segment))
                stream += streamSize
            }
            guard stream == start + remaining else { throw Failure.corrupt("jump table") }
            try table.decode(streams)
        }
        return (regenerated, header + compressed)
    }

    private enum Kind { case literalLength, offset, matchLength }

    private func table(mode: Int, kind: Kind, previous: FSETable?, at position: inout Int, size: Int) throws -> FSETable {
        let maxSymbol = kind == .literalLength ? 35 : kind == .offset ? 31 : 52
        switch mode {
        case 0:
            return kind == .literalLength ? Self.predefinedLiterals : kind == .offset ? Self.predefinedOffsets : Self.predefinedMatches
        case 1:
            guard position < size else { throw Failure.corrupt("rle table") }
            let symbol = Int(block[position])
            position += 1
            guard symbol <= maxSymbol else { throw Failure.corrupt("rle symbol") }
            return FSETable.rle(UInt8(symbol))
        case 2:
            let maxLog = kind == .offset ? 8 : 9
            let (norm, log, used) = try FSETable.readCounts(block + position, count: size - position,
                                                            maxSymbol: maxSymbol, maxLog: maxLog)
            position += used
            return try FSETable(norm: norm, log: log)
        default:
            guard let previous else { throw Failure.corrupt("repeat table without a previous one") }
            return previous
        }
    }

    // MARK: Code tables (RFC 8878 §3.1.1.3.2.1)

    private static let literalBase = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1_024, 2_048,
                                                    4_096, 8_192, 16_384, 32_768, 65_536]
    private static let literalBits = [Int](repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
                                                                      13, 14, 15, 16]
    private static let matchBase = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1_027, 2_051,
                                                  4_099, 8_195, 16_387, 32_771, 65_539]
    private static let matchBits = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13,
                                                                    14, 15, 16]
    private static let predefinedLiterals = try! FSETable(norm: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2,
                                                                 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], log: 6)
    private static let predefinedMatches = try! FSETable(norm: [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                                                1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                                                1, 1, 1, -1, -1, -1, -1, -1, -1, -1], log: 6)
    private static let predefinedOffsets = try! FSETable(norm: [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                                                1, 1, -1, -1, -1, -1, -1], log: 5)
}

// MARK: - Bit readers

private func highBit(_ value: Int) -> Int { Int.bitWidth - 1 - value.leadingZeroBitCount }

/// Reads a bitstream backwards from its end marker. Memory must stay readable 8 bytes past the stream (the block
/// buffer is padded). Reads past the start yield zeros and leave `position` negative, which callers treat as corrupt.
private struct BackwardBits {
    let base: UnsafePointer<UInt8>
    private(set) var position: Int

    init(_ base: UnsafePointer<UInt8>, count: Int) throws {
        guard count > 0, base[count - 1] != 0 else { throw ZstdReader.Failure.corrupt("bitstream marker") }
        self.base = base
        position = (count - 1) * 8 + highBit(Int(base[count - 1]))
    }

    init(_ base: UnsafePointer<UInt8>, position: Int) {
        self.base = base
        self.position = position
    }

    var exhausted: Bool { position == 0 }
    var overflowed: Bool { position < 0 }

    @inline(__always) func peek(_ count: Int) -> Int {
        let start = position - count
        if start >= 0 {
            let word = UInt64(littleEndian: UnsafeRawPointer(base + (start >> 3)).loadUnaligned(as: UInt64.self))
            return Int(truncatingIfNeeded: (word >> UInt64(start & 7)) & ((1 << UInt64(count)) &- 1))
        }
        guard position > 0 else { return 0 }
        let word = UInt64(littleEndian: UnsafeRawPointer(base).loadUnaligned(as: UInt64.self))
        return Int(truncatingIfNeeded: word & ((1 << UInt64(position)) - 1)) << -start
    }

    @inline(__always) mutating func read(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let value = peek(count)
        position -= count
        return value
    }

    @inline(__always) mutating func skip(_ count: Int) { position -= count }
}

// MARK: - FSE

private struct FSETable {
    let log: Int
    let symbol: [UInt8]
    let bits: [UInt8]
    let base: [UInt16]

    static func rle(_ value: UInt8) -> FSETable { FSETable(log: 0, symbol: [value], bits: [0], base: [0]) }

    private init(log: Int, symbol: [UInt8], bits: [UInt8], base: [UInt16]) {
        self.log = log
        self.symbol = symbol
        self.bits = bits
        self.base = base
    }

    init(norm: [Int], log: Int) throws {
        let size = 1 << log
        var symbol = [UInt8](repeating: 0, count: size)
        var next = [Int](repeating: 0, count: norm.count)
        var high = size - 1
        for (value, count) in norm.enumerated() where count == -1 {
            guard high >= 0 else { throw ZstdReader.Failure.corrupt("fse counts") }
            symbol[high] = UInt8(value)
            high -= 1
            next[value] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for (value, count) in norm.enumerated() where count > 0 {
            next[value] = count
            for _ in 0..<count {
                symbol[position] = UInt8(value)
                repeat { position = (position + step) & (size - 1) } while position > high
            }
        }
        guard position == 0 else { throw ZstdReader.Failure.corrupt("fse spread") }
        var bits = [UInt8](repeating: 0, count: size)
        var base = [UInt16](repeating: 0, count: size)
        for index in 0..<size {
            let value = Int(symbol[index])
            let state = next[value]
            next[value] += 1
            guard state > 0 else { throw ZstdReader.Failure.corrupt("fse state") }
            let count = log - highBit(state)
            bits[index] = UInt8(count)
            base[index] = UInt16((state << count) - size)
        }
        self.init(log: log, symbol: symbol, bits: bits, base: base)
    }

    /// Reads normalized counts (RFC 8878 §4.1.1); returns the counts, accuracy log and bytes used.
    static func readCounts(_ base: UnsafePointer<UInt8>, count: Int, maxSymbol: Int, maxLog: Int) throws
        -> (norm: [Int], log: Int, used: Int) {
        var position = 0
        func peek(_ width: Int) -> Int {
            var value = 0
            for bit in 0..<width {
                let index = position + bit
                guard index >> 3 < count else { break }
                value |= Int((base[index >> 3] >> UInt8(index & 7)) & 1) << bit
            }
            return value
        }
        let log = peek(4) + 5
        position += 4
        guard log <= maxLog else { throw ZstdReader.Failure.corrupt("fse accuracy") }
        var remaining = (1 << log) + 1
        var threshold = 1 << log
        var width = log + 1
        var norm = [Int]()
        var previousZero = false
        while remaining > 1 && norm.count <= maxSymbol {
            if previousZero {
                var zeros = 0
                while peek(2) == 3 { zeros += 3; position += 2 }
                zeros += peek(2)
                position += 2
                guard norm.count + zeros <= maxSymbol + 1 else { throw ZstdReader.Failure.corrupt("fse zeros") }
                norm += [Int](repeating: 0, count: zeros)
                guard norm.count <= maxSymbol else { break }
            }
            let maximum = (2 * threshold - 1) - remaining
            var value = peek(width)
            if value & (threshold - 1) < maximum {
                value &= threshold - 1
                position += width - 1
            } else {
                if value >= threshold { value -= maximum }
                position += width
            }
            let probability = value - 1
            remaining -= abs(probability)
            norm.append(probability)
            previousZero = probability == 0
            guard remaining >= 1 else { throw ZstdReader.Failure.corrupt("fse counts") }
            while remaining < threshold { width -= 1; threshold >>= 1 }
        }
        let used = (position + 7) >> 3
        guard remaining == 1, used <= count else { throw ZstdReader.Failure.corrupt("fse counts") }
        return (norm, log, used)
    }
}

// MARK: - Huffman

private struct HuffmanTable {
    let maxBits: Int
    /// `symbol | bits << 8`, indexed by the next `maxBits` bits.
    let entries: [UInt16]

    static func read(_ base: UnsafePointer<UInt8>, count: Int) throws -> (HuffmanTable, Int) {
        guard count > 0 else { throw ZstdReader.Failure.corrupt("huffman header") }
        let header = Int(base[0])
        var weights = [Int]()
        let used: Int
        if header < 128 {
            used = 1 + header
            guard header > 0, used <= count else { throw ZstdReader.Failure.corrupt("huffman weights size") }
            let (norm, log, countsUsed) = try FSETable.readCounts(base + 1, count: header, maxSymbol: 255, maxLog: 6)
            let table = try FSETable(norm: norm, log: log)
            var bits = try BackwardBits(base + 1 + countsUsed, count: header - countsUsed)
            var first = bits.read(log)
            var second = bits.read(log)
            while true {
                guard weights.count < 255 else { throw ZstdReader.Failure.corrupt("huffman weights") }
                weights.append(Int(table.symbol[first]))
                first = Int(table.base[first]) + bits.read(Int(table.bits[first]))
                if bits.overflowed { weights.append(Int(table.symbol[second])); break }
                weights.append(Int(table.symbol[second]))
                second = Int(table.base[second]) + bits.read(Int(table.bits[second]))
                if bits.overflowed { weights.append(Int(table.symbol[first])); break }
            }
        } else {
            let total = header - 127
            used = 1 + (total + 1) / 2
            guard used <= count else { throw ZstdReader.Failure.corrupt("huffman weights size") }
            for index in 0..<total {
                let packed = Int(base[1 + index / 2])
                weights.append(index % 2 == 0 ? packed >> 4 : packed & 15)
            }
        }
        guard weights.count <= 255 else { throw ZstdReader.Failure.corrupt("huffman weights") }
        var sum = 0
        for weight in weights {
            guard weight <= 11 else { throw ZstdReader.Failure.corrupt("huffman weight") }
            if weight > 0 { sum += 1 << (weight - 1) }
        }
        guard sum > 0 else { throw ZstdReader.Failure.corrupt("huffman weights") }
        let maxBits = highBit(sum) + 1
        let leftover = (1 << maxBits) - sum
        guard maxBits <= 11, leftover & (leftover - 1) == 0 else { throw ZstdReader.Failure.corrupt("huffman tree") }
        weights.append(highBit(leftover) + 1)
        var start = [Int](repeating: 0, count: 13)
        var counts = [Int](repeating: 0, count: 13)
        for weight in weights where weight > 0 { counts[weight] += 1 }
        var next = 0
        for weight in 1...12 {
            start[weight] = next
            next += counts[weight] << (weight - 1)
        }
        guard next == 1 << maxBits else { throw ZstdReader.Failure.corrupt("huffman tree") }
        var entries = [UInt16](repeating: 0, count: 1 << maxBits)
        for (symbol, weight) in weights.enumerated() where weight > 0 {
            let length = 1 << (weight - 1)
            let entry = UInt16(symbol) | UInt16(maxBits + 1 - weight) << 8
            for index in start[weight]..<start[weight] + length { entries[index] = entry }
            start[weight] += length
        }
        return (HuffmanTable(maxBits: maxBits, entries: entries), used)
    }

    struct Stream {
        let base: UnsafePointer<UInt8>
        let count: Int
        let output: UnsafeMutablePointer<UInt8>
        let symbols: Int
    }

    /// Decodes one or four independent streams. The four are interleaved so their table lookups overlap.
    func decode(_ streams: [Stream]) throws {
        let maxBits = self.maxBits
        let mask = (1 << maxBits) - 1
        var positions = try streams.map { try BackwardBits($0.base, count: $0.count).position }
        var done = [Int](repeating: 0, count: streams.count)
        entries.withUnsafeBufferPointer { table in
            @inline(__always) func four(_ stream: Stream, _ position: inout Int, _ index: Int) {
                // One load supplies at least 56 bits, enough for four codes of at most 11 bits.
                let byte = (position - 56) >> 3
                let word = Int(truncatingIfNeeded: UInt64(littleEndian: UnsafeRawPointer(stream.base + byte).loadUnaligned(as: UInt64.self)))
                var top = position - byte * 8
                for step in 0..<4 {
                    let entry = table[(word >> (top - maxBits)) & mask]
                    stream.output[index + step] = UInt8(truncatingIfNeeded: entry)
                    top -= Int(entry >> 8)
                }
                position = byte * 8 + top
            }
            if streams.count == 4 {
                let (a, b, c, d) = (streams[0], streams[1], streams[2], streams[3])
                var (pa, pb, pc, pd) = (positions[0], positions[1], positions[2], positions[3])
                let limit = min(a.symbols, b.symbols, c.symbols, d.symbols)
                var index = 0
                while index + 4 <= limit && min(pa, pb, pc, pd) >= 56 {
                    four(a, &pa, index)
                    four(b, &pb, index)
                    four(c, &pc, index)
                    four(d, &pd, index)
                    index += 4
                }
                positions = [pa, pb, pc, pd]
                done = [index, index, index, index]
            }
            for (number, stream) in streams.enumerated() {
                var position = positions[number]
                var index = done[number]
                while position >= 56 && index + 4 <= stream.symbols {
                    four(stream, &position, index)
                    index += 4
                }
                var bits = BackwardBits(stream.base, position: position)
                while index < stream.symbols {
                    let entry = table[bits.peek(maxBits)]
                    stream.output[index] = UInt8(truncatingIfNeeded: entry)
                    bits.skip(Int(entry >> 8))
                    index += 1
                }
                positions[number] = bits.position
            }
        }
        guard positions.allSatisfy({ $0 == 0 }) else { throw ZstdReader.Failure.corrupt("huffman stream end") }
    }
}

// MARK: - XXH64 (content checksum)

struct XXH64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private var v1 = p1 &+ p2
    private var v2 = p2
    private var v3: UInt64 = 0
    private var v4 = 0 &- p1
    private var total: UInt64 = 0
    private var pending = [UInt8]()

    @inline(__always) private static func rotate(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ lane: UInt64) -> UInt64 {
        rotate(acc &+ lane &* p2, 31) &* p1
    }

    private static func lane(_ pointer: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: pointer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let start = bytes.baseAddress, !bytes.isEmpty else { return }
        total += UInt64(bytes.count)
        var offset = 0
        if !pending.isEmpty {
            let take = min(32 - pending.count, bytes.count)
            pending.append(contentsOf: UnsafeRawBufferPointer(start: start, count: take))
            offset = take
            guard pending.count == 32 else { return }
            let full = pending
            pending.removeAll(keepingCapacity: true)
            full.withUnsafeBytes { stripe($0.baseAddress!) }
        }
        while bytes.count - offset >= 32 {
            stripe(start + offset)
            offset += 32
        }
        if offset < bytes.count { pending.append(contentsOf: UnsafeRawBufferPointer(start: start + offset, count: bytes.count - offset)) }
    }

    private mutating func stripe(_ pointer: UnsafeRawPointer) {
        v1 = Self.round(v1, Self.lane(pointer, 0))
        v2 = Self.round(v2, Self.lane(pointer, 8))
        v3 = Self.round(v3, Self.lane(pointer, 16))
        v4 = Self.round(v4, Self.lane(pointer, 24))
    }

    func digest() -> UInt64 {
        var hash: UInt64
        if total >= 32 {
            hash = Self.rotate(v1, 1) &+ Self.rotate(v2, 7) &+ Self.rotate(v3, 12) &+ Self.rotate(v4, 18)
            for value in [v1, v2, v3, v4] { hash = (hash ^ Self.round(0, value)) &* Self.p1 &+ Self.p4 }
        } else {
            hash = Self.p5
        }
        hash &+= total
        pending.withUnsafeBytes { raw in
            var offset = 0
            while raw.count - offset >= 8 {
                hash = Self.rotate(hash ^ Self.round(0, Self.lane(raw.baseAddress!, offset)), 27) &* Self.p1 &+ Self.p4
                offset += 8
            }
            if raw.count - offset >= 4 {
                let word = UInt64(UInt32(littleEndian: raw.baseAddress!.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                hash = Self.rotate(hash ^ (word &* Self.p1), 23) &* Self.p2 &+ Self.p3
                offset += 4
            }
            while offset < raw.count {
                hash = Self.rotate(hash ^ (UInt64(raw[offset]) &* Self.p5), 11) &* Self.p1
                offset += 1
            }
        }
        hash ^= hash >> 33
        hash &*= Self.p2
        hash ^= hash >> 29
        hash &*= Self.p3
        hash ^= hash >> 32
        return hash
    }
}
