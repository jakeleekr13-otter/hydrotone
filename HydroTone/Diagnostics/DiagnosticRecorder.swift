import Foundation
import os

actor DiagnosticRecorder {
    struct Event: Codable, Sendable {
        var minute: Int
        var operation: Operation
        var failure: Failure
        var count: Int
    }
    private struct ReportEvent: Codable {
        var operation: Operation
        var failure: Failure
        var count: Int
    }
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "diagnostics")
    private let directory: URL
    private var events: [Event] = []
    private var lastWrite = Date.distantPast
    private let window: TimeInterval = 60
    private static let maxEvents = 64
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HydroToneDiagnostics", isDirectory: true)
        let saved = self.directory.appendingPathComponent("events.json")
        if let size = try? saved.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 128_000,
           let data = try? Data(contentsOf: saved), let decoded = try? JSONDecoder().decode([Event].self, from: data) {
            events = Array(decoded.suffix(Self.maxEvents))
        }
    }
    func record(_ failure: Failure, operation: Operation, occurrences: Int = 1, now: Date = Date()) {
        guard failure.kind != .cancelled, occurrences > 0 else { return }
        let minute = Int(now.timeIntervalSince1970 / window)
        events.removeAll { $0.minute < minute - 7 * 24 * 60 }
        if let last = events.lastIndex(where: { $0.minute == minute && $0.operation == operation && $0.failure == failure }) {
            events[last].count = min(1_000_000, events[last].count + occurrences)
        } else {
            events.append(Event(minute: minute, operation: operation, failure: failure,
                                count: min(1_000_000, occurrences)))
            if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
            // All public values are a fixed operation/kind/domain allowlist or numeric code.
            logger.error("operation=\(operation.rawValue, privacy: .public) kind=\(failure.kind.rawValue, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        }
        if now.timeIntervalSince(lastWrite) >= 30 { flush(now: now) }
    }
    func snapshot() -> [Event] { events }
    func flush(now: Date = Date()) {
        do {
            try prepareDirectory()
            try JSONEncoder().encode(events).write(to: directory.appendingPathComponent("events.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastWrite = now
        } catch { logger.notice("Could not persist local diagnostic summary") }
    }
    func receiveMetricKit(_ data: Data, type: String) {
        // MetricKit data stays local. Keep at most six reports, each at most one MiB.
        guard data.count <= 1_048_576, ["metric", "diagnostic"].contains(type) else { return }
        do {
            try prepareDirectory()
            let url = directory.appendingPathComponent("\(type)-\(UUID().uuidString).json")
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            pruneReports()
        } catch { logger.notice("Could not retain local MetricKit report") }
    }
    func exportReport() throws -> URL {
        flush()
        pruneReports()
        // Do not expose per-event timestamps. The exported report only needs frequency.
        let grouped = Dictionary(grouping: events) { "\($0.operation.rawValue)|\($0.failure.kind.rawValue)|\($0.failure.domain)|\($0.failure.code)" }
            .values.compactMap { group -> ReportEvent? in
                guard let first = group.first else { return nil }
                return ReportEvent(operation: first.operation, failure: first.failure,
                                   count: group.reduce(0) { min(1_000_000, $0 + $1.count) })
            }
        let eventData = try JSONEncoder().encode(grouped)
        var report: [String: Any] = [
            "schema": 1, "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "events": try JSONSerialization.jsonObject(with: eventData)]
        let reports = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        report["metricKit"] = reports.filter { $0.lastPathComponent != "events.json" }.compactMap { url -> Any? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        let output = try TemporaryFiles.makeURL(extension: "json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return output
    }
    func clear() {
        events.removeAll()
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: url) }
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func pruneReports() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let reports = urls.filter { $0.lastPathComponent != "events.json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (index, url) in reports.enumerated() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if index >= 6 || Date().timeIntervalSince(modified) > 7 * 24 * 60 * 60 { try? FileManager.default.removeItem(at: url) }
        }
    }
}
