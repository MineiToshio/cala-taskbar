import Foundation

/// Calendar chrome follows the first preferred language; unsupported languages use English.
func calendarText(_ english: String, _ spanish: String, preferredLanguage: String? = Locale.preferredLanguages.first) -> String {
    let language = preferredLanguage?.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
    return language == "es" ? spanish : english
}
