import Foundation

/// The language the app shows (its main bundle's pick among its localizations: en, fr), with the user's region.
/// Formatters use it, so a Mac in an unsupported language never mixes English sentences with units in its own language.
public enum AppLanguage {
    public static var locale: Locale {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }
}

/// Strings of the core, from its own tables (`Resources/{en,fr}.lproj`; SwiftPM 6.1 does not compile a String Catalog).
/// `locale` nil: the app's language (`AppLanguage`). An explicit locale (tests) picks that language's table and formats
/// numbers and plurals with it.
enum L10n {
    static func string(_ value: String.LocalizationValue, locale: Locale?) -> String {
        let locale = locale ?? AppLanguage.locale
        return String(localized: value, bundle: bundle(for: locale), locale: locale)
    }

    /// The `.lproj` of the locale's language; English for a language the core does not have.
    static func bundle(for locale: Locale) -> Bundle {
        let code = locale.language.languageCode?.identifier ?? "en"
        for language in [code, "en"] {
            if let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .module
    }
}
