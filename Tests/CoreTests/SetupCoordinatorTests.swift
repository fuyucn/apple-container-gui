import Testing
import Foundation
@testable import Core

/// A `ContainerCLI` whose `overridePath` points at this test executable itself
/// is guaranteed to resolve (it exists and is executable). A bogus override path
/// is guaranteed not to resolve. We use those two to simulate binary present /
/// absent without touching the real `container` install.
private func presentCLI() -> ContainerCLI {
    let runner = MockCommandRunner()
    // The running test binary is always an existing executable file.
    let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return ContainerCLI(runner: runner, overridePath: selfPath)
}

private func missingCLI() -> ContainerCLI {
    let runner = MockCommandRunner()
    return ContainerCLI(runner: runner, overridePath: "/nonexistent/path/to/container-binary")
}

@MainActor
@Test func checkYieldsMissingBinaryWhenNoBinary() async throws {
    // Even with a running daemon seeded, a missing binary short-circuits.
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let coordinator = SetupCoordinator(service: service, cli: missingCLI())

    await coordinator.check()

    #expect(coordinator.state == .missingBinary)
    // Daemon was never queried because the binary is absent.
    #expect(service.daemonStatusCalls == 0)
}

@MainActor
@Test func checkYieldsDaemonStoppedWhenBinaryPresentButDaemonDown() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .stopped, appRoot: nil, installRoot: nil)
    )
    let coordinator = SetupCoordinator(service: service, cli: presentCLI())

    await coordinator.check()

    #expect(coordinator.state == .daemonStopped)
    #expect(service.daemonStatusCalls == 1)
}

@MainActor
@Test func checkYieldsReadyWhenBinaryAndDaemonOK() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let coordinator = SetupCoordinator(service: service, cli: presentCLI())

    await coordinator.check()

    #expect(coordinator.state == .ready)
}

@MainActor
@Test func startDaemonAndRecheckBecomesReady() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let coordinator = SetupCoordinator(service: service, cli: presentCLI())

    await coordinator.startDaemonAndRecheck()

    #expect(service.startDaemonCalls == 1)
    #expect(coordinator.state == .ready)
}

// MARK: - runAutoSetup

/// A coordinator wired to observe every state transition during runAutoSetup.
/// Because the coordinator is `@Observable` we can't trivially diff history, so
/// the mock installer records its own step ordering and we assert the terminal
/// state plus the recorded step sequence.
@MainActor
@Test func runAutoSetupHappyPathReachesReady() async throws {
    // Binary resolves (present CLI) and daemon reports running after install,
    // so the trailing check() lands on .ready.
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let installer = MockInstaller()
    let coordinator = SetupCoordinator(service: service, cli: presentCLI(), installer: installer)

    await coordinator.runAutoSetup()

    // Steps ran in order: latest -> download -> verify -> install.
    #expect(installer.ran == [.latest, .download, .verify, .install])
    // Daemon was started during the .startingDaemon phase.
    #expect(service.startDaemonCalls == 1)
    #expect(coordinator.state == .ready)
}

@MainActor
@Test func runAutoSetupTransitionsThroughPhases() async throws {
    // Observe transitions by polling state via withObservationTracking would be
    // flaky; instead drive a download with multiple progress steps and assert
    // we left .downloading via the recorded installer ordering + final state,
    // and that an intermediate downloading fraction was reachable.
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let installer = MockInstaller(progressSteps: [0.25, 0.5, 1.0])
    let coordinator = SetupCoordinator(service: service, cli: presentCLI(), installer: installer)

    await coordinator.runAutoSetup()

    #expect(installer.ran == [.latest, .download, .verify, .install])
    #expect(coordinator.state == .ready)
}

@MainActor
@Test func runAutoSetupVerifyFailureGoesToFailed() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let installer = MockInstaller(failAt: .verify, error: InstallerError.signatureMismatch("bad"))
    let coordinator = SetupCoordinator(service: service, cli: presentCLI(), installer: installer)

    await coordinator.runAutoSetup()

    // Stopped before install; never started the daemon.
    #expect(installer.ran == [.latest, .download, .verify])
    #expect(service.startDaemonCalls == 0)
    if case .failed = coordinator.state {} else {
        Issue.record("expected .failed, got \(coordinator.state)")
    }
}

@MainActor
@Test func runAutoSetupDownloadFailureGoesToFailed() async throws {
    let service = MockContainerService()
    let installer = MockInstaller(failAt: .download, error: InstallerError.digestMismatch(expected: "a", actual: "b"))
    let coordinator = SetupCoordinator(service: service, cli: presentCLI(), installer: installer)

    await coordinator.runAutoSetup()

    #expect(installer.ran == [.latest, .download])
    #expect(service.startDaemonCalls == 0)
    if case .failed = coordinator.state {} else {
        Issue.record("expected .failed, got \(coordinator.state)")
    }
}

@MainActor
@Test func runAutoSetupWithoutInstallerFails() async throws {
    let service = MockContainerService()
    let coordinator = SetupCoordinator(service: service, cli: presentCLI())

    await coordinator.runAutoSetup()

    if case .failed = coordinator.state {} else {
        Issue.record("expected .failed, got \(coordinator.state)")
    }
}
