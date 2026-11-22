import Foundation
@testable import AzPimCore
import Testing

struct SpikeL10nTests {
    @Test func plural() {
        let french = Locale(identifier: "fr_FR")
        #expect(L10n.string("\(1) active", locale: french) == "1 rôle actif")
        #expect(L10n.string("\(4) active", locale: french) == "4 rôles actifs")
        #expect(L10n.string("\(4) active", locale: Locale(identifier: "en")) == "4 active")
    }
}
