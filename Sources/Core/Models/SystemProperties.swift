import Foundation

/// Read-only view of the container runtime's VM resource configuration, parsed
/// from `system property list` (container v1.0.0).
///
/// That command outputs TOML (there is NO `--format json` and NO write path on a
/// default install), grouped into sections like `[build]`, `[container]`,
/// `[machine]`, `[kernel]`. Each line within a section is `key = value`, where
/// values may be quoted strings, bare numbers, or bare booleans. This model
/// keeps the raw `[section: [key: value]]` map (string values, quotes stripped)
/// plus typed convenience accessors for the build/container CPUs & memory the
/// Settings pane displays.
///
/// `Sendable` so the view model on the main actor can hold and pass it freely.
public struct SystemProperties: Sendable, Equatable {
    /// All parsed sections: section name → (key → value). Values have any
    /// surrounding quotes stripped. Empty sections (a `[name]` header with no
    /// keys) are present with an empty dictionary.
    public let sections: [String: [String: String]]

    public init(sections: [String: [String: String]]) {
        self.sections = sections
    }

    /// Look up a single key's value within a section.
    public func value(section: String, key: String) -> String? {
        sections[section]?[key]
    }

    // MARK: - Typed convenience accessors

    /// `[build] cpus` as an integer, when present and numeric.
    public var buildCPUs: Int? { value(section: "build", key: "cpus").flatMap(Int.init) }
    /// `[build] memory` (a string like `"2048mb"`), when present.
    public var buildMemory: String? { value(section: "build", key: "memory") }
    /// `[container] cpus` as an integer, when present and numeric.
    public var containerCPUs: Int? { value(section: "container", key: "cpus").flatMap(Int.init) }
    /// `[container] memory` (a string like `"1gb"`), when present.
    public var containerMemory: String? { value(section: "container", key: "memory") }

    // MARK: - Parsing

    /// Parse `system property list` TOML output into sections. Tolerant: blank
    /// lines and `#` comments are skipped; a `[section]` header opens a section;
    /// a `key = value` line adds to the current section (lines before any header
    /// are ignored). Values are trimmed and have one layer of surrounding
    /// matching quotes (`"` or `'`) stripped.
    public init(parsingTOML text: String) {
        var sections: [String: [String: String]] = [:]
        var current: String? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                current = name
                // Register the (possibly empty) section so it round-trips.
                if sections[name] == nil { sections[name] = [:] }
                continue
            }

            guard let section = current,
                  let eq = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            sections[section, default: [:]][key] = Self.unquote(rawValue)
        }

        self.sections = sections
    }

    /// Strip one layer of surrounding matching quotes (`"` or `'`) from a value.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first!
        let last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
