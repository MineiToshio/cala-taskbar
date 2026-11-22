import Foundation

func diskBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

enum MemoryDisplayUnit: Equatable {
    case gigabyteTenths, megabytes

    init(total: UInt64) {
        self = total >= 1_073_741_824 ? .gigabyteTenths : .megabytes
    }

    func count(forBytes bytes: UInt64) -> Double {
        switch self {
        case .gigabyteTenths: return Double(bytes) * 10 / 1_073_741_824
        case .megabytes: return Double(bytes) / 1_048_576
        }
    }

    func roundedCount(forBytes bytes: UInt64) -> Int {
        Int(count(forBytes: bytes).rounded(.toNearestOrEven))
    }

    func text(_ count: Int, locale: Locale) -> String {
        let usesGB = self == .gigabyteTenths
        let value = usesGB ? Double(count) / 10 : Double(count)
        let format = NumberFormatter()
        format.locale = locale
        format.numberStyle = .decimal
        format.usesGroupingSeparator = false
        format.minimumFractionDigits = usesGB ? 1 : 0
        format.maximumFractionDigits = format.minimumFractionDigits
        return (format.string(from: NSNumber(value: value)) ?? String(value)) + (usesGB ? " GB" : " MB")
    }
}

struct MemoryDisplay: Equatable {
    let unit: MemoryDisplayUnit
    let count: Int

    func text(locale: Locale) -> String { unit.text(count, locale: locale) }
}

func memoryText(_ bytes: UInt64, locale: Locale = .current) -> String {
    let unit = MemoryDisplayUnit(total: bytes)
    return unit.text(unit.roundedCount(forBytes: bytes), locale: locale)
}
