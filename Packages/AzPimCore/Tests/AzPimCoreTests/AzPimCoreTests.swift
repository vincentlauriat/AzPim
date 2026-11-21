import Testing
@testable import AzPimCore

@Test func coreVersionIsSemantic() {
    let parts = AzPimCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
