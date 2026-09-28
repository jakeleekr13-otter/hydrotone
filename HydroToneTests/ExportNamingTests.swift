import XCTest
@testable import HydroTone

final class ExportNamingTests: XCTestCase {
    let date = DateComponents(calendar: .current, year: 2026, month: 9, day: 28, hour: 14, minute: 30, second: 5).date!

    func testSourceNameKeepsItsStemAndAddsTheLook() {
        XCTAssertEqual(ExportNaming.fileName(source: "IMG_1234.HEIC", preset: .natural, extension: "jpg"), "IMG_1234_HydroTone_NaturalDive.jpg")
        XCTAssertEqual(ExportNaming.fileName(source: "DSC03545.ARW", preset: .deep, extension: "jpg"), "DSC03545_HydroTone_DeepDive.jpg")
        XCTAssertEqual(ExportNaming.fileName(source: "Dive 3.mov", preset: .custom, extension: "mov"), "Dive 3_HydroTone_Custom.mov")
        XCTAssertEqual(ExportNaming.fileName(source: "바다 사진.jpg", preset: .tropical, extension: "jpg"), "바다 사진_HydroTone_Tropical.jpg")
    }

    func testMissingOrTemporaryNamesFallBackToTheExportTime() {
        XCTAssertEqual(ExportNaming.fileName(source: nil, preset: .natural, extension: "jpg", date: date), "HydroTone_20260928_143005_NaturalDive.jpg")
        XCTAssertEqual(ExportNaming.fileName(source: UUID().uuidString + ".heic", preset: .original, extension: "jpg", date: date),
                       "HydroTone_20260928_143005_Original.jpg")
        XCTAssertEqual(ExportNaming.fileName(source: " ..jpg", preset: .natural, extension: "jpg", date: date), "HydroTone_20260928_143005_NaturalDive.jpg")
    }

    func testReEditingReplacesTheLookInsteadOfStacking() {
        XCTAssertEqual(ExportNaming.fileName(source: "IMG_1234_HydroTone_NaturalDive.jpg", preset: .tropical, extension: "jpg"),
                       "IMG_1234_HydroTone_Tropical.jpg")
        XCTAssertEqual(ExportNaming.fileName(source: "HydroTone_20260101_090000_DeepDive.jpg", preset: .custom, extension: "jpg", date: date),
                       "HydroTone_20260101_090000_Custom.jpg")
    }

    func testUnsafeCharactersAndLongNamesAreCleaned() {
        XCTAssertEqual(ExportNaming.fileName(source: "a/b:c*?.png", preset: .natural, extension: "jpg"), "a_b_c_HydroTone_NaturalDive.jpg")
        let long = String(repeating: "x", count: 100) + ".jpg"
        XCTAssertEqual(ExportNaming.stem(from: long)?.count, ExportNaming.maxSourceLength)
    }
}
