import Testing
import Foundation
@testable import Core

/// A throwaway `UserDefaults` suite so each test reads/writes an isolated domain
/// and never touches the real user preferences. Cleared on creation.
@MainActor
private func makeDefaults(_ suite: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
@Test func appSettingsReadsDefaultsWhenUnset() {
    let settings = AppSettings(defaults: makeDefaults())

    #expect(settings.colorScheme == .system)
    #expect(settings.confirmBeforeDelete == true)
    #expect(settings.activityPollIntervalSeconds == 2)
    #expect(settings.defaultRunCPUs == nil)
    #expect(settings.defaultRunMemoryMiB == nil)
    #expect(settings.containerBinaryPathOverride == nil)
}

@MainActor
@Test func appSettingsColorSchemeRoundTrips() {
    let defaults = makeDefaults()
    let settings = AppSettings(defaults: defaults)

    settings.colorScheme = .dark
    #expect(settings.colorScheme == .dark)
    // Persisted to the backing store, so a fresh instance reads it back.
    #expect(AppSettings(defaults: defaults).colorScheme == .dark)

    settings.colorScheme = .light
    #expect(settings.colorScheme == .light)
}

@MainActor
@Test func appSettingsConfirmBeforeDeleteRoundTrips() {
    let defaults = makeDefaults()
    let settings = AppSettings(defaults: defaults)

    settings.confirmBeforeDelete = false
    #expect(settings.confirmBeforeDelete == false)
    #expect(AppSettings(defaults: defaults).confirmBeforeDelete == false)

    settings.confirmBeforeDelete = true
    #expect(settings.confirmBeforeDelete == true)
}

@MainActor
@Test func appSettingsActivityPollIntervalRoundTrips() {
    let defaults = makeDefaults()
    let settings = AppSettings(defaults: defaults)

    settings.activityPollIntervalSeconds = 5
    #expect(settings.activityPollIntervalSeconds == 5)
    #expect(AppSettings(defaults: defaults).activityPollIntervalSeconds == 5)
}

@MainActor
@Test func appSettingsActivityPollIntervalClampsNonPositiveToDefault() {
    let settings = AppSettings(defaults: makeDefaults())

    settings.activityPollIntervalSeconds = 0
    #expect(settings.activityPollIntervalSeconds == 2)
}

@MainActor
@Test func appSettingsDefaultRunCPUsRoundTrips() {
    let defaults = makeDefaults()
    let settings = AppSettings(defaults: defaults)

    settings.defaultRunCPUs = 4
    #expect(settings.defaultRunCPUs == 4)
    #expect(AppSettings(defaults: defaults).defaultRunCPUs == 4)

    settings.defaultRunCPUs = nil
    #expect(settings.defaultRunCPUs == nil)
    #expect(AppSettings(defaults: defaults).defaultRunCPUs == nil)
}

@MainActor
@Test func appSettingsDefaultRunMemoryRoundTrips() {
    let defaults = makeDefaults()
    let settings = AppSettings(defaults: defaults)

    settings.defaultRunMemoryMiB = 2048
    #expect(settings.defaultRunMemoryMiB == 2048)
    #expect(AppSettings(defaults: defaults).defaultRunMemoryMiB == 2048)

    settings.defaultRunMemoryMiB = nil
    #expect(settings.defaultRunMemoryMiB == nil)
}

@MainActor
@Test func appSettingsBinaryPathOverrideRoundTrips() {
    let defaults = makeDefaults()
    let settings = AppSettings(defaults: defaults)

    settings.containerBinaryPathOverride = "/opt/homebrew/opt/container/bin/container"
    #expect(settings.containerBinaryPathOverride == "/opt/homebrew/opt/container/bin/container")
    #expect(AppSettings(defaults: defaults).containerBinaryPathOverride == "/opt/homebrew/opt/container/bin/container")

    settings.containerBinaryPathOverride = nil
    #expect(settings.containerBinaryPathOverride == nil)
}

@MainActor
@Test func appSettingsBinaryPathOverrideNormalizesBlankToNil() {
    let settings = AppSettings(defaults: makeDefaults())

    settings.containerBinaryPathOverride = "   "
    #expect(settings.containerBinaryPathOverride == nil)

    settings.containerBinaryPathOverride = ""
    #expect(settings.containerBinaryPathOverride == nil)
}
