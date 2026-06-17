import Foundation
@testable import Core

/// Test `HTTPClient` returning canned `data(for:)` responses. `bytes(for:)` is
/// not exercised by the installer unit tests (the real byte stream is hard to
/// fabricate without a server), so it traps if called.
struct MockHTTPClient: HTTPClient {
    let body: Data
    let statusCode: Int
    let url: URL

    init(body: Data, statusCode: Int = 200, url: URL = URL(string: "https://api.github.com/x")!) {
        self.body = body
        self.statusCode = statusCode
        self.url = url
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("MockHTTPClient.bytes(for:) is not used in unit tests")
    }
}
