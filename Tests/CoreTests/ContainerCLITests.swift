import Testing
import Foundation
@testable import Core

@Test func resolvesExistingOverridePath() async {
    // /bin/echo is guaranteed to exist; use it as an override stand-in.
    let cli = ContainerCLI(runner: MockCommandRunner(), overridePath: "/bin/echo")
    let path = await cli.resolveBinaryPath()
    #expect(path == "/bin/echo")
}

@Test func returnsNilWhenNothingExists() async {
    let cli = ContainerCLI(
        runner: MockCommandRunner(),
        overridePath: "/no/such/binary/anywhere-xyz"
    )
    let path = await cli.resolveBinaryPath()
    #expect(path == nil)
}

@Test func versionReturnsTrimmedStdout() async {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "container CLI version 1.0.0\n", stderr: ""))
    let cli = ContainerCLI(runner: mock, overridePath: "/bin/echo")
    let v = await cli.version()
    #expect(v == "container CLI version 1.0.0")
    // version() resolves the binary then runs `<path> --version`.
    #expect(mock.calls == [["/bin/echo", "--version"]])
}

@Test func versionReturnsNilWhenBinaryUnresolvable() async {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "x", stderr: ""))
    let cli = ContainerCLI(runner: mock, overridePath: "/no/such/binary-xyz")
    let v = await cli.version()
    #expect(v == nil)
    #expect(mock.calls.isEmpty)  // never ran a command — nothing to resolve
}
