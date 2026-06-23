import Foundation

/// Drives the images list UI: holds the current `[ContainerImage]`, refreshes
/// it, removes images, and pulls (accumulating streamed progress lines into
/// `pullLog`).
@MainActor
@Observable
public final class ImagesViewModel {
    /// Images as of the last refresh.
    public private(set) var images: [ContainerImage] = []

    /// Names (`ContainerImage.name`) of images currently referenced by an
    /// existing container, as of the last refresh. Computed by cross-referencing
    /// the image list against `listContainers()` with reference normalization
    /// (see `ImageUsage`). Drives the "In Use" vs other grouping in the UI.
    public private(set) var inUseNames: Set<String> = []

    /// Accumulated progress lines from the most recent `pull`.
    public private(set) var pullLog: [String] = []

    /// Whether a pull is currently in progress.
    public private(set) var isPulling = false

    /// Accumulated progress lines from the most recent `push`.
    public private(set) var pushLog: [String] = []

    /// Whether a push is currently in progress.
    public private(set) var isPushing = false

    /// The most recent error surfaced by a refresh, action, or pull.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read the image list from the service, and recompute `inUseNames` by
    /// also listing containers and cross-referencing their image references.
    /// A failure to list containers does not fail the refresh: images still
    /// load and `inUseNames` degrades to empty (everything shown ungrouped).
    public func refresh() async {
        do {
            let images = try await service.listImages()
            self.images = images
            let containers = (try? await service.listContainers()) ?? []
            inUseNames = ImageUsage.inUseNames(
                images: images,
                containerReferences: containers.map(\.imageReference)
            )
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

    /// Fetch an image's run-time defaults (suggested env + exposed ports) for
    /// prefilling the Run sheet. Failures degrade to an empty `ImageConfig`
    /// (plain form) rather than surfacing an error, since prefill is a
    /// convenience: a missing/un-inspectable image should not block the form.
    public func imageConfig(for ref: String) async -> ImageConfig {
        do {
            return try await service.imageConfig(ref)
        } catch {
            return ImageConfig()
        }
    }

    /// Export an image to an OCI tar archive at `path` (`image save`). Does not
    /// refresh the list (an export does not change the image set); errors are
    /// captured into `lastError`.
    public func exportImage(ref: String, to path: String) async {
        do {
            try await service.saveImage(ref, to: path)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Load (import) an image from a tar archive at `path` (`image load`), then
    /// refresh so the imported image appears in the list. The inverse of
    /// `exportImage`; errors are captured into `lastError`.
    public func loadImage(from path: String) async {
        do {
            try await service.loadImage(from: path)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Remove all unused images (`image prune`), then refresh.
    public func prune() async {
        do {
            try await service.pruneImages()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Create a new reference `newRef` for the existing image `source`
    /// (`image tag`), then refresh so the new tag appears.
    public func tag(source: String, newRef: String) async {
        do {
            try await service.tagImage(source: source, newRef: newRef)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Push an image, accumulating each streamed progress line into `pushLog`.
    /// Mirrors `pull`: clears the log, flips `isPushing`, and surfaces any error
    /// via `lastError`. Does not refresh the local image list (a push does not
    /// change it).
    public func push(ref: String) async {
        pushLog = []
        isPushing = true
        lastError = nil
        defer { isPushing = false }

        do {
            for try await line in service.pushImage(ref) {
                pushLog.append(line)
            }
        } catch {
            lastError = String(describing: error)
        }
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
