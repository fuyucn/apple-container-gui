import Foundation

/// Locates the `container` binary and runs metadata queries against it.
///
/// The `container` CLI is NOT assumed to be installed or on `PATH`; this type
/// discovers it by searching, in order: an explicit override, the Homebrew
/// formula bin, the common manual-install locations, and finally `PATH`.
public struct ContainerCLI: Sendable {
    private let runner: CommandRunner
    private let overridePath: String?

    /// Well-known install locations searched after the override and before
    /// falling back to a `PATH` lookup.
    private static let searchDirectories = [
        "/opt/homebrew/opt/container/bin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ]

    public init(runner: CommandRunner, overridePath: String? = nil) {
        self.runner = runner
        self.overridePath = overridePath
    }

    /// Returns the absolute path to the `container` binary, or `nil` if it
    /// cannot be found. Search order: `overridePath`, the well-known install
    /// directories, then `PATH` (`/usr/bin/env`-style lookup).
    public func resolveBinaryPath() async -> String? {
        let fm = FileManager.default

        // 1. Explicit override.
        if let override = overridePath {
            if isExecutableFile(override, fm) { return override }
            // An override that does not exist is authoritative: do not fall
            // back to searching, since the caller pinned a specific path.
            return nil
        }

        // 2. Well-known directories.
        for dir in Self.searchDirectories {
            let candidate = dir + "/container"
            if isExecutableFile(candidate, fm) { return candidate }
        }

        // 3. PATH lookup via `/usr/bin/which`.
        if let fromPath = await resolveViaPATH() { return fromPath }

        return nil
    }

    /// Runs `<binary> --version` and returns the trimmed stdout, or `nil` when
    /// the binary cannot be resolved or the command fails.
    public func version() async -> String? {
        guard let path = await resolveBinaryPath() else { return nil }
        do {
            let result = try await runner.run(path, ["--version"])
            guard result.exitCode == 0 else { return nil }
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func isExecutableFile(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return fm.isExecutableFile(atPath: path)
    }

    private func resolveViaPATH() async -> String? {
        do {
            let result = try await runner.run("/usr/bin/which", ["container"])
            guard result.exitCode == 0 else { return nil }
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
