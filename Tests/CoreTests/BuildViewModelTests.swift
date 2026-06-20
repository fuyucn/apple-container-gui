import Testing
import Foundation
@testable import Core

@Test func suggestedTagDerivesPackageFromParentDirWith5CharSuffix() {
    let url = URL(fileURLWithPath: "/Users/yuf/Developer/video-screenshot/Dockerfile")
    let tag = BuildViewModel.suggestedTag(forDockerfileAt: url)

    #expect(tag.hasPrefix("video-screenshot-"))
    #expect(tag.hasSuffix(":latest"))
    // "<package>-<5 chars>:latest" → strip prefix and ":latest", 5 chars remain.
    let suffix = tag.dropFirst("video-screenshot-".count).dropLast(":latest".count)
    #expect(suffix.count == 5)
    #expect(suffix.allSatisfy { $0.isLetter || $0.isNumber })
    // Two calls differ in the random suffix (unique-ish).
    #expect(BuildViewModel.suggestedTag(forDockerfileAt: url) != tag)
}

@Test func suggestedTagSanitizesNonAlnumDirName() {
    let url = URL(fileURLWithPath: "/tmp/My App (v2)/Dockerfile")
    let tag = BuildViewModel.suggestedTag(forDockerfileAt: url)
    #expect(tag.hasPrefix("my-app-v2-"))
    #expect(tag.hasSuffix(":latest"))
}

@MainActor
@Test func buildAccumulatesLogLinesAndSucceeds() async throws {
    let service = MockContainerService(streamLines: ["STEP 1/3", "STEP 2/3", "Successfully built"])
    let vm = BuildViewModel(service: service)

    #expect(vm.status == .idle)

    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "myapp:latest")

    #expect(vm.logLines == ["STEP 1/3", "STEP 2/3", "Successfully built"])
    #expect(vm.status == .succeeded)
    #expect(service.buildInvocations.count == 1)
    #expect(service.buildInvocations.first?.tag == "myapp:latest")
}

@MainActor
@Test func buildFailureSetsFailedStatusAndKeepsPartialLog() async throws {
    let service = MockContainerService(
        streamLines: ["STEP 1/3"],
        streamError: ContainerError.commandFailed("build failed")
    )
    let vm = BuildViewModel(service: service)

    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "t:1")

    #expect(vm.logLines == ["STEP 1/3"])
    if case .failed(let message) = vm.status {
        #expect(message.contains("build failed"))
    } else {
        Issue.record("expected .failed status, got \(vm.status)")
    }
}

@MainActor
@Test func builtImageTagUsesRequestedTagAfterSuccess() async throws {
    let service = MockContainerService(streamLines: ["STEP 1/2", "Successfully built resolved/name:1.0"])
    let vm = BuildViewModel(service: service)

    #expect(vm.builtImageTag == nil)

    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "myapp:latest")

    #expect(vm.status == .succeeded)
    #expect(vm.builtImageTag == "myapp:latest")
}

@MainActor
@Test func builtImageTagFallsBackToLastLogLineWhenTagEmpty() async throws {
    let service = MockContainerService(streamLines: ["STEP 1/2", "  ", "resolved/name:1.0", "  "])
    let vm = BuildViewModel(service: service)

    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "")

    #expect(vm.status == .succeeded)
    #expect(vm.builtImageTag == "resolved/name:1.0")
}

@MainActor
@Test func builtImageTagNilBeforeAndAfterFailedBuild() async throws {
    let service = MockContainerService(
        streamLines: ["STEP 1/3"],
        streamError: ContainerError.commandFailed("build failed")
    )
    let vm = BuildViewModel(service: service)

    #expect(vm.builtImageTag == nil)

    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "t:1")

    if case .failed = vm.status {} else {
        Issue.record("expected .failed status, got \(vm.status)")
    }
    #expect(vm.builtImageTag == nil)
}

@MainActor
@Test func buildResetsLogOnSecondRun() async throws {
    let service = MockContainerService(streamLines: ["only line"])
    let vm = BuildViewModel(service: service)

    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "a")
    await vm.build(dockerfile: "Dockerfile", context: ".", tag: "b")

    #expect(vm.logLines == ["only line"])
    #expect(service.buildInvocations.count == 2)
}
