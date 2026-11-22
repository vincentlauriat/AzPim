import Foundation

/// Strings of the core, from its own String Catalog (`Resources/Localizable.xcstrings`).
/// `locale` nil: the system language, as the app shows it. An explicit locale (tests) picks that language's table and
/// formats numbers and plurals with it.
enum L10n {
    static func string(_ value: String.LocalizationValue, locale: Locale?) -> String {
        guard let locale else { return String(localized: value, bundle: .module) }
        return String(localized: value, bundle: bundle(for: locale), locale: locale)
    }

    /// The `.lproj` of the locale's language; the module bundle (English) for a language the core does not have.
    static func bundle(for locale: Locale) -> Bundle {
        guard let code = locale.language.languageCode?.identifier,
              let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .module }
        return bundle
    }
}
