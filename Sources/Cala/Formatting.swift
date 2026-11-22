import Foundation

func diskBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func memoryText(_ bytes: UInt64, locale: Locale = .current) -> String {
    let gib = 1_073_741_824.0
    let format = NumberFormatter()
    format.locale = locale
    format.numberStyle = .decimal
    format.usesGroupingSeparator = false
    let inGigabytes = Double(bytes) >= gib
    format.minimumFractionDigits = inGigabytes ? 1 : 0
    format.maximumFractionDigits = format.minimumFractionDigits
    let value = Double(bytes) / (inGigabytes ? gib : 1_048_576)
    return (format.string(from: NSNumber(value: value)) ?? String(value)) + (inGigabytes ? " GB" : " MB")
}
