import Foundation
@testable import Core

/// Shared fixture-decoding helpers for view-model tests, so a `MockContainerService`
/// can be seeded with real fixture-decoded domain values.
enum ViewModelFixtures {
    private enum FixtureError: Error { case notFound(String) }

    private static func load(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    static func containers() throws -> [Container] {
        try JSONDecoder().decode([Container].self, from: load("container-list.json"))
    }

    static func images() throws -> [ContainerImage] {
        try JSONDecoder().decode([ContainerImage].self, from: load("image-list.json"))
    }

    static func volumes() throws -> [ContainerVolume] {
        try JSONDecoder().decode([ContainerVolume].self, from: load("volumes.json"))
    }

    static func networks() throws -> [ContainerNetwork] {
        try JSONDecoder().decode([ContainerNetwork].self, from: load("networks.json"))
    }
}
