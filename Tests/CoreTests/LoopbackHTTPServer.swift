import Foundation
import Network

/// A throwaway loopback HTTP/1.1 server that answers the first GET with a fixed
/// body and a correct `Content-Length`. Used to exercise the real
/// `URLSession.bytes` download path (which cannot be faked, as
/// `URLSession.AsyncBytes` is not constructible) against deterministic bytes.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL

    init(body: Data) throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let response = Self.httpResponse(body: body)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            // Read the request (ignored) then write the canned response.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: .global())
        ready.wait()

        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "LoopbackHTTPServer", code: 1)
        }
        self.url = URL(string: "http://127.0.0.1:\(port)/pkg")!
    }

    func stop() { listener.cancel() }

    private static func httpResponse(body: Data) -> Data {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/octet-stream\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}
