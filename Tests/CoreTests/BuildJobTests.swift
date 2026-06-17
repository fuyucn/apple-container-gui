import Testing
import Foundation
@testable import Core

@Test func buildJobStartsRunningWithNoLines() {
    let job = BuildJob(tag: "myimage:latest")
    #expect(job.status == .running)
    #expect(job.logLines.isEmpty)
    #expect(job.tag == "myimage:latest")
}

@Test func buildJobAccumulatesLogLines() {
    var job = BuildJob(tag: "t")
    job.append("step 1/3")
    job.append("step 2/3")
    #expect(job.logLines == ["step 1/3", "step 2/3"])
    #expect(job.status == .running)
}

@Test func buildJobSucceedsTransition() {
    var job = BuildJob(tag: "t")
    job.append("building")
    job.markSucceeded()
    #expect(job.status == .succeeded)
}

@Test func buildJobFailsTransitionWithMessage() {
    var job = BuildJob(tag: "t")
    job.markFailed("dockerfile not found")
    #expect(job.status == .failed("dockerfile not found"))
}
