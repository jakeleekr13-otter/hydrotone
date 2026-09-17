import XCTest
@testable import HydroTone

@MainActor
final class TrialTests: XCTestCase {
    final class MemoryPersistence: TrialPersistence {
        var value = TrialState()
        var fail = false
        func read() throws -> TrialState { if fail { throw HydroError.trialUnavailable }; return value }
        func write(_ state: TrialState) throws { if fail { throw HydroError.trialUnavailable }; value = state }
    }
    func testExactlyOnePhotoAndOneTenSecondVideoWithRollback() throws {
        let persistence = MemoryPersistence()
        let trial = TrialStore(persistence: persistence)
        XCTAssertEqual(TrialStore.videoSeconds, 10)
        try trial.reserve(.photo)
        XCTAssertFalse(trial.canExport(.photo))
        try trial.rollback()
        XCTAssertTrue(trial.canExport(.photo))
        try trial.reserve(.photo); try trial.commit(.photo)
        XCTAssertFalse(trial.canExport(.photo)); XCTAssertTrue(trial.canExport(.video))
        let restored = TrialStore(persistence: persistence)
        XCTAssertFalse(restored.canExport(.photo))
        try restored.reserve(.video); try restored.commit(.video)
        XCTAssertFalse(restored.canExport(.video))
    }
    func testInterruptedExportRefundsOnNextLaunch() throws {
        let persistence = MemoryPersistence()
        let trial = TrialStore(persistence: persistence)
        try trial.reserve(.video)
        XCTAssertTrue(TrialStore(persistence: persistence).canExport(.video))
    }
    func testPersistenceFailureDoesNotGrantExports() throws {
        let persistence = MemoryPersistence(); persistence.fail = true
        let trial = TrialStore(persistence: persistence)
        XCTAssertFalse(trial.canExport(.photo))
        XCTAssertThrowsError(try trial.reserve(.photo))
    }
    func testRealKeychainRoundTrip() throws {
        let persistence = KeychainTrialPersistence(service: "com.hydrotone.test.\(UUID().uuidString)")
        var state = try persistence.read()
        XCTAssertFalse(state.photoUsed)
        state.photoUsed = true
        try persistence.write(state)
        XCTAssertEqual(try persistence.read(), state)
    }
}
