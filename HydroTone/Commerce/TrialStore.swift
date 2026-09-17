import Foundation
import Observation
import Security

struct TrialState: Codable, Equatable {
    var photoUsed = false
    var videoUsed = false
    var pending: String?
    func available(_ kind: ImportedMedia.Kind) -> Bool { kind == .photo ? !photoUsed : !videoUsed }
}
protocol TrialPersistence {
    func read() throws -> TrialState
    func write(_ state: TrialState) throws
}
struct KeychainTrialPersistence: TrialPersistence {
    let service: String
    init(service: String = "com.hydrotone.trial.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "local-trial", kSecAttrSynchronizable as String: false]
    }
    func read() throws -> TrialState {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return TrialState() }
        guard status == errSecSuccess, let data = result as? Data,
              let state = try? JSONDecoder().decode(TrialState.self, from: data) else { throw HydroError.trialUnavailable }
        return state
    }
    func write(_ state: TrialState) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw HydroError.trialUnavailable }
        } else if status != errSecSuccess { throw HydroError.trialUnavailable }
    }
}

@MainActor @Observable
final class TrialStore {
    static let videoSeconds: Double = 10
    private(set) var state = TrialState()
    private(set) var available = false
    private let persistence: any TrialPersistence
    private let diagnostics: DiagnosticRecorder?
    init(persistence: any TrialPersistence = KeychainTrialPersistence(), diagnostics: DiagnosticRecorder? = nil) {
        self.diagnostics = diagnostics
        self.persistence = persistence
        reload()
    }
    func reload() {
        do {
            var saved = try persistence.read()
            // A pending export from a terminated process produced no deliverable file.
            if saved.pending != nil { saved.pending = nil; try persistence.write(saved) }
            state = saved; available = true
        } catch {
            available = false
            let failure = Failure.classify(error, operation: .trial)
            Task { await diagnostics?.record(failure, operation: .trial) }
        }
    }
    func canExport(_ kind: ImportedMedia.Kind) -> Bool { available && state.pending == nil && state.available(kind) }
    func reserve(_ kind: ImportedMedia.Kind) throws {
        guard canExport(kind) else { throw HydroError.trialUnavailable }
        var next = state
        next.pending = kind == .photo ? "photo" : "video"
        try persistence.write(next); state = next
    }
    func commit(_ kind: ImportedMedia.Kind) throws {
        guard state.pending == (kind == .photo ? "photo" : "video") else { throw HydroError.trialUnavailable }
        var next = state
        if kind == .photo { next.photoUsed = true } else { next.videoUsed = true }
        next.pending = nil
        try persistence.write(next); state = next
    }
    func rollback() throws {
        var next = state; next.pending = nil
        try persistence.write(next); state = next
    }
}
