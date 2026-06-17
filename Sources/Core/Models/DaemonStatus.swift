import Foundation

/// Parsed result of `container system status`, which emits a two-column
/// `FIELD   VALUE` text table (not JSON). Only the fields the GUI needs are
/// extracted; unknown rows are ignored.
public struct DaemonStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case stopped
        case unknown

        init(string: String) {
            switch string.lowercased() {
            case "running": self = .running
            case "stopped": self = .stopped
            default: self = .unknown
            }
        }
    }

    public let state: State
    public let appRoot: String?
    public let installRoot: String?

    public init(state: State, appRoot: String?, installRoot: String?) {
        self.state = state
        self.appRoot = appRoot
        self.installRoot = installRoot
    }

    /// Parse the `FIELD   VALUE` text table. Each data row is a field name
    /// followed by whitespace and its value (the value may itself contain
    /// spaces). A missing `status` row degrades to `.unknown`.
    public init(parsingText text: String) {
        var fields: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            // Split into the first whitespace-delimited token (field) and the rest (value).
            guard let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let field = String(line[line.startIndex..<firstSpace])
            let value = line[firstSpace...].trimmingCharacters(in: .whitespaces)
            // Skip the header row.
            if field == "FIELD" { continue }
            fields[field] = value
        }

        self.state = State(string: fields["status"] ?? "")
        self.appRoot = fields["appRoot"].flatMap { $0.isEmpty ? nil : $0 }
        self.installRoot = fields["installRoot"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
