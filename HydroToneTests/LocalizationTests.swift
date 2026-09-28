import XCTest
@testable import HydroTone

final class LocalizationTests: XCTestCase {
    func localized(_ key: String, _ locale: String) throws -> String {
        let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    func testSupportedLanguagesAndEnglishFallback() {
        XCTAssertEqual(try localized("Select Photo", "ko"), "사진 선택")
        XCTAssertEqual(try localized("Select Photo", "ja"), "写真を選択")
        XCTAssertEqual(try localized("Select Photo", "zh-Hans"), "选择照片")
        XCTAssertEqual(try localized("Select Photo", "zh-Hant"), "選擇照片")
        // English is the development language and therefore the bundle fallback for unsupported locales.
        XCTAssertEqual(try localized("Select Photo", "en"), "Select Photo")
    }

    func testImportStringsAreLocalized() {
        XCTAssertEqual(try localized("Import from Files", "ko"), "파일에서 가져오기")
        XCTAssertEqual(try localized("Only the first %lld photos were opened.", "zh-Hant"), "僅開啟了前 %lld 張照片。")
    }

    func testErrorMessagesAreLocalized() {
        XCTAssertEqual(try localized("There isn’t enough free storage. Free up some space and try again.", "ko"),
                       "저장 공간이 부족합니다. 공간을 확보한 후 다시 시도하세요.")
        XCTAssertNotEqual(try localized("The export couldn’t finish. Please try again.", "ja"),
                          "The export couldn’t finish. Please try again.")
    }
}
