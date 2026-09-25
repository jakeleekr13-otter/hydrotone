import XCTest
import AVFoundation
import Synchronization
@testable import HydroTone

final class DiagnosticsTests: XCTestCase {
    func testFrequentFailuresAreClassifiedWithoutPrivateDetails() {
        let path = "/private/var/mobile/secret-dive.mov"
        let unknown = NSError(domain: "CameraOwner.\(path)", code: 77,
                              userInfo: [NSLocalizedDescriptionKey: "Jake's \(path)"])
        let failure = Failure.classify(unknown, operation: .export)
        XCTAssertEqual(failure.kind, .exportFailed)
        XCTAssertEqual(failure.domain, "Other")
        XCTAssertFalse(failure.message.contains("Jake"))
        XCTAssertFalse(failure.message.contains("secret-dive"))

        let nested = NSError(domain: NSCocoaErrorDomain, code: 1,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: AVFoundationErrorDomain,
                                                                      code: AVError.diskFull.rawValue)])
        XCTAssertEqual(Failure.classify(nested, operation: .export).kind, .storage)
        XCTAssertEqual(Failure.classify(URLError(.timedOut), operation: .importing).kind, .network)
        XCTAssertEqual(Failure.classify(CancellationError(), operation: .export).kind, .cancelled)
    }

    func testReadRetryIsBoundedAndOnlyRetriesTransientFailures() async throws {
        final class Counter: Sendable {
            private let value = Mutex(0)
            var count: Int { value.withLock { $0 } }
            @discardableResult func increment() -> Int { value.withLock { $0 += 1; return $0 } }
        }
        let transient = Counter()
        let result: String = try await SafeReadRetry(maximumAttempts: 3).run(operation: .inspection) {
            if transient.increment() < 3 { throw URLError(.networkConnectionLost) }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(transient.count, 3)

        let permanent = Counter()
        do {
            let _: String = try await SafeReadRetry(maximumAttempts: 3).run(operation: .inspection) {
                permanent.increment()
                throw HydroError.unsupported
            }
            XCTFail("Permanent failure unexpectedly succeeded")
        } catch { XCTAssertEqual(permanent.count, 1) }
    }

    func testRecorderCoalescesBurstsAndExportContainsNoMediaDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = DiagnosticRecorder(directory: directory)
        let failure = Failure(kind: .network, domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let time = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<100 { await recorder.record(failure, operation: .importing, now: time) }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.count, 100)
        let report = try await recorder.exportReport()
        defer { TemporaryFiles.remove(report); try? FileManager.default.removeItem(at: directory) }
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertFalse(text.contains(".mov"))
        XCTAssertFalse(text.contains("/private/"))
        XCTAssertFalse(text.contains("\"minute\""))
        XCTAssertLessThan(text.utf8.count, 128_000)
    }

    func testRestorationFallbacksAreAggregatedWithoutUnderlyingErrorDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = DiagnosticRecorder(directory: directory)
        await recorder.record(.restorationFallback(.videoInitialAnalysis),
                              operation: .videoRestoration, occurrences: 3)
        await recorder.record(.restorationFallback(.videoInitialAnalysis),
                              operation: .videoRestoration, occurrences: 2)

        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.operation, .videoRestoration)
        XCTAssertEqual(events.first?.failure.kind, .restorationFallback)
        XCTAssertEqual(events.first?.failure.domain, "HydroTone")
        XCTAssertEqual(events.first?.failure.code,
                       Failure.RestorationStage.videoInitialAnalysis.rawValue)
        XCTAssertEqual(events.first?.count, 5)

        let report = try await recorder.exportReport()
        defer { TemporaryFiles.remove(report); try? FileManager.default.removeItem(at: directory) }
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(text.contains("videoRestoration"))
        XCTAssertTrue(text.contains("restorationFallback"))
        XCTAssertFalse(text.contains("localizedDescription"))
        XCTAssertFalse(text.contains("userInfo"))
    }
}
