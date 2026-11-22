import Foundation

/// Language chosen in Settings → General ("en" or "es"); nil follows the system. Set once at launch and when the
/// setting changes, on the main thread.
nonisolated(unsafe) var appLanguageOverride: String?

/// The interface language: the one chosen in Settings, else the Mac's first preferred language.
var appLanguage: String? { appLanguageOverride ?? Locale.preferredLanguages.first }

/// Interface text in the interface language; anything other than Spanish uses English.
func calendarText(_ english: String, _ spanish: String, preferredLanguage: String? = appLanguage) -> String {
    let language = preferredLanguage?.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
    return language == "es" ? spanish : english
}

/// Interface text in the user's language: Spanish when it is their first preferred language, English otherwise.
func tx(_ english: String, _ spanish: String) -> String { calendarText(english, spanish) }
