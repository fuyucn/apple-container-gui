import Foundation

/// One component's version, decoded from `system version --format json`
/// (container v1.0.0), which emits an array of
/// `{appName, buildType, commit, version}` objects (e.g. `container` and
/// `container-apiserver`). Only `appName`/`version` are surfaced.
///
/// `Sendable` so the view model on the main actor can hold and pass it freely.
public struct SystemVersion: Sendable, Equatable, Decodable {
    /// The component name, e.g. `container` or `container-apiserver`.
    public let appName: String
    /// The component's version string.
    public let version: String

    public init(appName: String, version: String) {
        self.appName = appName
        self.version = version
    }

    /// Decode the `system version --format json` array. Throws
    /// `ContainerError.decodingFailed` on malformed JSON.
    public static func parse(json: String) throws -> [SystemVersion] {
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode([SystemVersion].self, from: data)
        } catch {
            throw ContainerError.decodingFailed(String(describing: error))
        }
    }
}
