import Foundation

/// Drives the networks list UI: holds the current `[ContainerNetwork]`, refreshes
/// it, creates networks, and removes them.
@MainActor
@Observable
public final class NetworksViewModel {
    /// Networks as of the last refresh.
    public private(set) var networks: [ContainerNetwork] = []

    /// The most recent error surfaced by a refresh or action.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read the network list from the service.
    public func refresh() async {
        do {
            networks = try await service.listNetworks()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Create a network, then refresh.
    public func create(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async {
        do {
            try await service.createNetwork(name: name, internal: isInternal, subnet: subnet, labels: labels)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Remove a network, then refresh.
    public func remove(_ name: String) async {
        do {
            try await service.removeNetwork(name)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }
}
