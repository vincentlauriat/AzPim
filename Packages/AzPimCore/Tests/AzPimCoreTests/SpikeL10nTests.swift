import Foundation
@testable import AzPimCore
import Testing

struct SpikeL10nTests {
    @Test func plural() {
        let fr = Locale(identifier: "fr_FR")
        #expect(L10n.string("\(1) active", locale: fr) == "1 rôle actif")
        #expect(L10n.string("\(4) active", locale: fr) == "4 rôles actifs")
        #expect(L10n.string("\(4) active", locale: Locale(identifier: "en")) == "4 active")
    }
}
