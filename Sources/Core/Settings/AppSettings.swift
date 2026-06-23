import Foundation

/// The user's preferred color scheme for the app window. `system` defers to the
/// OS appearance; `light`/`dark` force the corresponding scheme. Persisted as
/// its `rawValue` string so it survives launches.
public enum AppColorScheme: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// A human-readable label for the Appearance picker.
    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Persisted, unit-testable application preferences.
///
/// `@MainActor @Observable` so SwiftUI views observe each property directly and
/// writes round-trip through the backing `UserDefaults` synchronously. The
/// `UserDefaults` store is injected (defaults to `.standard`) so tests can pass
/// a throwaway suite and assert the set/get round-trip and the default values
/// without touching the real user domain.
///
/// Every property is a thin computed wrapper over a single `UserDefaults` key:
/// the getter reads (falling back to the documented default), the setter writes.
/// This keeps the store free of caching/sync bugs — `UserDefaults` is the single
/// source of truth — while `@Observable` still notifies SwiftUI on each write
/// (the stored `version` tick is mutated inside every setter to trigger
/// observation, since the values themselves live in `UserDefaults`).
@MainActor
@Observable
public final class AppSettings {
    /// UserDefaults keys. Namespaced to avoid collisions with system keys.
    public enum Key {
        public static let colorScheme = "settings.colorScheme"
        public static let confirmBeforeDelete = "settings.confirmBeforeDelete"
        public static let activityPollIntervalSeconds = "settings.activityPollIntervalSeconds"
        public static let defaultRunCPUs = "settings.defaultRunCPUs"
        public static let defaultRunMemoryMiB = "settings.defaultRunMemoryMiB"
        public static let containerBinaryPathOverride = "settings.containerBinaryPathOverride"
    }

    /// Documented defaults applied when a key has never been written.
    public enum Default {
        public static let colorScheme: AppColorScheme = .system
        public static let confirmBeforeDelete = true
        public static let activityPollIntervalSeconds: Double = 2
    }

    private let defaults: UserDefaults

    /// A monotonic tick bumped inside every setter purely so `@Observable`
    /// publishes a change (the real values live in `UserDefaults`, which
    /// `@Observable` cannot itself observe).
    private var version = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Appearance

    /// Preferred color scheme. Defaults to `.system`. An unrecognized stored
    /// string also falls back to `.system`.
    public var colorScheme: AppColorScheme {
        get {
            _ = version
            guard let raw = defaults.string(forKey: Key.colorScheme),
                  let scheme = AppColorScheme(rawValue: raw)
            else { return Default.colorScheme }
            return scheme
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.colorScheme)
            version += 1
        }
    }

    // MARK: - Behavior

    /// Whether destructive actions show a confirmation dialog first. Defaults to
    /// `true`.
    public var confirmBeforeDelete: Bool {
        get {
            _ = version
            guard defaults.object(forKey: Key.confirmBeforeDelete) != nil else {
                return Default.confirmBeforeDelete
            }
            return defaults.bool(forKey: Key.confirmBeforeDelete)
        }
        set {
            defaults.set(newValue, forKey: Key.confirmBeforeDelete)
            version += 1
        }
    }

    // MARK: - Activity Monitor

    /// Activity Monitor poll cadence in seconds. Defaults to `2`. Clamped to a
    /// sane floor so a stored 0 never produces a busy loop.
    public var activityPollIntervalSeconds: Double {
        get {
            _ = version
            guard defaults.object(forKey: Key.activityPollIntervalSeconds) != nil else {
                return Default.activityPollIntervalSeconds
            }
            let stored = defaults.double(forKey: Key.activityPollIntervalSeconds)
            return stored > 0 ? stored : Default.activityPollIntervalSeconds
        }
        set {
            defaults.set(newValue, forKey: Key.activityPollIntervalSeconds)
            version += 1
        }
    }

    // MARK: - Run defaults

    /// Default CPU count to prefill the Run sheet with, or `nil` for none.
    public var defaultRunCPUs: Int? {
        get {
            _ = version
            guard defaults.object(forKey: Key.defaultRunCPUs) != nil else { return nil }
            return defaults.integer(forKey: Key.defaultRunCPUs)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.defaultRunCPUs)
            } else {
                defaults.removeObject(forKey: Key.defaultRunCPUs)
            }
            version += 1
        }
    }

    /// Default memory in MiB to prefill the Run sheet with, or `nil` for none.
    public var defaultRunMemoryMiB: Int? {
        get {
            _ = version
            guard defaults.object(forKey: Key.defaultRunMemoryMiB) != nil else { return nil }
            return defaults.integer(forKey: Key.defaultRunMemoryMiB)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.defaultRunMemoryMiB)
            } else {
                defaults.removeObject(forKey: Key.defaultRunMemoryMiB)
            }
            version += 1
        }
    }

    // MARK: - Advanced

    /// Explicit path to the `container` binary, overriding auto-discovery, or
    /// `nil` to auto-discover. Changing it takes effect on the next app launch
    /// (the service + CLI are composed once at startup). An empty/whitespace
    /// string is normalized to `nil`.
    public var containerBinaryPathOverride: String? {
        get {
            _ = version
            guard let value = defaults.string(forKey: Key.containerBinaryPathOverride),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Key.containerBinaryPathOverride)
            } else {
                defaults.removeObject(forKey: Key.containerBinaryPathOverride)
            }
            version += 1
        }
    }
}
