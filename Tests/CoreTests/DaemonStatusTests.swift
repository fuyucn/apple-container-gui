import Testing
import Foundation
@testable import Core

private func loadStatusFixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw StatusFixtureError.notFound(name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private enum StatusFixtureError: Error { case notFound(String) }

@Test func parsesRunningDaemonStatusFixture() throws {
    let text = try loadStatusFixture("system-status.txt")
    let status = DaemonStatus(parsingText: text)
    #expect(status.state == .running)
    #expect(status.appRoot == "/Users/yuf/Library/Application Support/com.apple.container/")
    #expect(status.installRoot == "/opt/homebrew/Cellar/container/1.0.0_1/")
}

@Test func parsesStoppedDaemonStatus() {
    let text = """
    FIELD              VALUE
    status             stopped
    """
    let status = DaemonStatus(parsingText: text)
    #expect(status.state == .stopped)
}

@Test func unknownStatusStringParsesToUnknown() {
    let text = """
    FIELD              VALUE
    status             gibberish
    """
    let status = DaemonStatus(parsingText: text)
    #expect(status.state == .unknown)
}

@Test func emptyTextParsesToUnknown() {
    let status = DaemonStatus(parsingText: "")
    #expect(status.state == .unknown)
    #expect(status.appRoot == nil)
}
