import Foundation
import AVFoundation
import Photos
import Security
import StoreKit

enum Operation: String, Codable, Sendable {
    case importing, inspection, preview, export, save, purchase, restore, trial, hdrProbe, productLoading
    case photoRestoration, videoRestoration
}

struct Failure: Error, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case cancelled, storage, permission, network, unreadable, unsupported, temporarilyUnavailable
        case exportFailed, invalidOutput, trialUnavailable, storeUnavailable, thermal, memoryPressure
        case restorationFallback
    }
    let kind: Kind
    let domain: String
    let code: Int
    var retrySafeRead: Bool { kind == .network || kind == .temporarilyUnavailable }
    var message: String {
        switch kind {
        case .cancelled: String(localized: "Cancelled")
        case .storage: String(localized: "There isn’t enough free storage. Free up some space and try again.")
        case .permission: String(localized: "Allow HydroTone to add to Photos in Settings, then try saving again.")
        case .network: String(localized: "This item may need to download from iCloud. Check your connection and try again.")
        case .unreadable: String(localized: "This media couldn’t be opened. Try another photo or video.")
        case .unsupported: String(localized: "This media format isn’t supported on this device.")
        case .temporarilyUnavailable: String(localized: "The media service is temporarily busy. Wait a moment and try again.")
        case .exportFailed: String(localized: "The export couldn’t finish. Please try again.")
        case .invalidOutput: String(localized: "The exported file didn’t pass our quality checks. Nothing was saved.")
        case .trialUnavailable: String(localized: "Trial access couldn’t be checked securely. Unlock your iPhone and try again.")
        case .storeUnavailable: String(localized: "The App Store couldn’t complete this request. Check your connection and try again.")
        case .memoryPressure: String(localized: "Memory is low. Try a smaller photo or a lower video resolution.")
        case .thermal: String(localized: "Your iPhone needs to cool down before exporting. Wait a moment and try again.")
        case .restorationFallback: String(localized: "Depth-aware restoration was unavailable, so HydroTone used its standard correction.")
        }
    }

    /// Stable, privacy-safe stages for restoration fallback diagnostics. Never encode the
    /// underlying model error because it can contain a media path or framework message.
    enum RestorationStage: Int, Sendable {
        case photoAnalysis = 1
        case photoRender = 2
        case videoInitialAnalysis = 3
        case videoTemporalAnalysis = 4
        case videoRender = 5
    }

    static func restorationFallback(_ stage: RestorationStage) -> Self {
        Self(kind: .restorationFallback, domain: "HydroTone", code: stage.rawValue)
    }
    static func classify(_ error: Error, operation: Operation) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return Self(kind: .cancelled, domain: "Swift", code: 0) }
        if let hydro = error as? HydroError {
            let kind: Kind
            switch hydro {
            case .unreadable: kind = .unreadable
            case .unsupported: kind = .unsupported
            case .exportFailed: kind = .exportFailed
            case .permission: kind = .permission
            case .storage: kind = .storage
            case .invalidOutput: kind = .invalidOutput
            case .trialUnavailable: kind = .trialUnavailable
            }
            return Self(kind: kind, domain: "HydroTone", code: 0)
        }
        let original = error as NSError
        var candidates = [original]
        var current = original
        for _ in 0..<4 {
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            candidates.append(underlying); current = underlying
        }
        for item in candidates {
            let kind: Kind?
            switch item.domain {
            case NSCocoaErrorDomain:
                kind = item.code == NSFileWriteOutOfSpaceError ? .storage : nil
            case NSURLErrorDomain:
                kind = item.code == NSURLErrorCancelled ? .cancelled :
                    [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(item.code) ? .network : nil
            case AVFoundationErrorDomain:
                switch item.code {
                case AVError.diskFull.rawValue: kind = .storage
                case AVError.mediaServicesWereReset.rawValue, AVError.decoderTemporarilyUnavailable.rawValue: kind = .temporarilyUnavailable
                case AVError.decodeFailed.rawValue, AVError.fileFormatNotRecognized.rawValue: kind = .unreadable
                case AVError.decoderNotFound.rawValue: kind = .unsupported
                default: kind = nil
                }
            case PHPhotosErrorDomain:
                switch item.code {
                case PHPhotosError.userCancelled.rawValue: kind = .cancelled
                case PHPhotosError.accessUserDenied.rawValue, PHPhotosError.accessRestricted.rawValue: kind = .permission
                case PHPhotosError.networkAccessRequired.rawValue, PHPhotosError.networkError.rawValue: kind = .network
                default: kind = nil
                }
            case NSOSStatusErrorDomain:
                kind = [Int(errSecInteractionNotAllowed), Int(errSecNotAvailable), Int(errSecMissingEntitlement)].contains(item.code) ? .trialUnavailable : nil
            default: kind = nil
            }
            if let kind { return Self(kind: kind, domain: safeDomain(item.domain), code: item.code) }
        }
        let fallback: Kind = operation == .purchase || operation == .restore || operation == .productLoading ? .storeUnavailable :
            operation == .trial ? .trialUnavailable : operation == .importing || operation == .inspection || operation == .preview ? .unreadable : .exportFailed
        return Self(kind: fallback, domain: safeDomain(original.domain), code: original.code)
    }
    private static func safeDomain(_ domain: String) -> String {
        // Never retain arbitrary error strings/domains, URLs, userInfo, paths or media names.
        [NSCocoaErrorDomain, NSURLErrorDomain, AVFoundationErrorDomain, PHPhotosErrorDomain, NSOSStatusErrorDomain, "StoreKit.StoreKitError"].contains(domain) ? domain : "Other"
    }
}

struct SafeReadRetry {
    let maximumAttempts: Int
    init(maximumAttempts: Int = 2) { self.maximumAttempts = min(3, max(1, maximumAttempts)) }
    func run<T>(operation: Operation, action: () async throws -> T) async throws -> T {
        precondition([.importing, .inspection, .preview, .productLoading].contains(operation), "Only repeat read-only work")
        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            do { return try await action() }
            catch {
                let failure = Failure.classify(error, operation: operation)
                guard failure.retrySafeRead, attempt < maximumAttempts else { throw error }
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
        throw HydroError.unreadable
    }
}
