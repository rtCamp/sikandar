import XCTest
import CoreData

/// Guards the store shipped with v1.0.0: the current model must open it with
/// lightweight migration and keep every row. `Sikandar.xcdatamodel` is frozen as
/// the v1.0.0 model; later changes go in a new model version. Re-capture the
/// fixture only when a new release ships.
final class MigrationTests: XCTestCase {
    private let fixtureName = "Sikandar-v1.0.0"
    private let expectedGames = 5, expectedPlayers = 9, expectedRounds = 173

    private func currentModel() throws -> NSManagedObjectModel {
        try XCTUnwrap(NSManagedObjectModel.mergedModel(from: [Bundle.main]), "Sikandar.momd not found in host app")
    }

    func testCurrentModelOpensV1StoreWithoutLosingData() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixtureName, withExtension: "sqlite"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Sikandar.sqlite")
        try FileManager.default.copyItem(at: fixture, to: url)

        let container = NSPersistentContainer(name: "Sikandar", managedObjectModel: try currentModel())
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError, "v1.0.0 store must open with the current model: \(String(describing: loadError))")

        let ctx = container.viewContext
        func count(_ entity: String) throws -> Int {
            try ctx.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
        }
        XCTAssertEqual(try count("Game"), expectedGames)
        XCTAssertEqual(try count("Player"), expectedPlayers)
        XCTAssertEqual(try count("GameRound"), expectedRounds)
    }

    func testV1ToCurrentIsLightweight() throws {
        let v1URL = try XCTUnwrap(Bundle.main.url(forResource: "Sikandar", withExtension: "mom", subdirectory: "Sikandar.momd"),
                                  "frozen v1.0.0 model missing from Sikandar.momd")
        let v1 = try XCTUnwrap(NSManagedObjectModel(contentsOf: v1URL))
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: v1, destinationModel: try currentModel())
        XCTAssertNotNil(mapping, "Change from v1.0.0 is not a lightweight migration — needs a staged/custom migration")
    }
}
