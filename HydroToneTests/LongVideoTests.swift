import XCTest
import Darwin
@testable import HydroTone

final class LongVideoTests: XCTestCase {
    actor Samples {
        var values: [UInt64] = []
        func record() {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if status == KERN_SUCCESS { values.append(info.resident_size) }
        }
    }
    func testTwoMinuteSequentialExportHasBoundedMemory() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "two_minutes", withExtension: "mov"))
        let metadata = try await MediaInspector().inspect(url)
        let samples = Samples()
        let result = try await VideoExporter().export(url: url, metadata: metadata, settings: .init(preset: .deep, analysis: .init(redLoss: 0.7)), options: .init()) { progress in
            if progress > 0.15 { await samples.record() }
        }
        defer { TemporaryFiles.remove(result.url) }
        XCTAssertEqual(result.frames, 3600)
        XCTAssertEqual(result.metadata.duration, 120, accuracy: 0.05)
        let memory = await samples.values
        XCTAssertGreaterThan(memory.count, 10)
        let growth = (memory.max() ?? 0) - (memory.min() ?? 0)
        print("Two-minute export: peak resident \((memory.max() ?? 0)/1_048_576) MiB, post-warmup range \(growth/1_048_576) MiB")
        XCTAssertLessThan(growth, 220 * 1_048_576, "Memory increased with clip duration")
    }
}
