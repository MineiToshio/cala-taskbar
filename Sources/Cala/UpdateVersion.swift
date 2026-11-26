import Foundation

struct AppVersion: Comparable {
    let version: String
    let build: Int
    private let components: [Int]

    init?(version: String, build: String) {
        guard let parts = Self.numbers(version, count: 3...3),
              let number = Self.numbers(build, count: 1...1)?.first else { return nil }
        self.version = version
        self.build = number
        components = parts
    }

    fileprivate static func numbers(_ text: String, count: ClosedRange<Int>) -> [Int]? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard count.contains(fields.count) else { return nil }
        let numbers = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(field)
        }
        return numbers.count == fields.count ? numbers : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components && lhs.build == rhs.build
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components ? lhs.build < rhs.build : lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    var identifier: String { components.map(String.init).joined(separator: ".") + "+\(build)" }

    static func supports(minimum: String, os: OperatingSystemVersion) -> Bool {
        guard var parts = numbers(minimum, count: 1...3) else { return false }
        parts += Array(repeating: 0, count: 3 - parts.count)
        return ![os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(parts)
    }
}
