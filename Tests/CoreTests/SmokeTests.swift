import Testing
@testable import Core

@Test func packageBuilds() {
    #expect(Core.version == "0.1.0")
}
