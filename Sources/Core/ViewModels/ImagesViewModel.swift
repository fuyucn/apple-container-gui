import Foundation

/// Drives the images list UI: holds the current `[ContainerImage]`, refreshes
/// it, removes images, and pulls (accumulating streamed progress lines into
/// `pullLog`).
@MainActor
@Observable
public final class ImagesViewModel {
    /// Images as of the last refresh.
    public private(set) var images: [ContainerImage] = []

    /// Accumulated progress lines from the most recent `pull`.
    public private(set) var pullLog: [String] = []

    /// Whether a pull is currently in progress.
    public private(set) var isPulling = false

    /// The most recent error surfaced by a refresh, action, or pull.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read the image list from the service.
    public func refresh() async {
        do {
            images = try await service.listImages()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Remove an image, then refresh.
    public func removeImage(_ id: String) async {
        do {
            try await service.removeImage(id)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Pull an image, accumulating each streamed progress line into `pullLog`.
    /// On success, refreshes the image list so the new image appears.
    public func pull(_ ref: String) async {
        pullLog = []
        isPulling = true
        lastError = nil
        defer { isPulling = false }

        do {
            for try await line in service.pullImage(ref) {
                pullLog.append(line)
            }
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }
}
