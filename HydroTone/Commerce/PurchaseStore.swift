import Foundation
import Observation
import StoreKit

@MainActor @Observable
final class PurchaseStore {
    static let productID = "com.hydrotone.pro"
    private(set) var product: Product?
    private(set) var isPro = false
    private(set) var busy = false
    private var entitlementGeneration = 0
    var message: String?
    @ObservationIgnored private var updates: Task<Void, Never>?
    private let diagnostics: DiagnosticRecorder?
    init(diagnostics: DiagnosticRecorder? = nil) {
        self.diagnostics = diagnostics
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if case .verified(let transaction) = result, transaction.productID == Self.productID {
                    self.accept(transaction)
                    await transaction.finish()
                }
            }
        }
    }
    isolated deinit { updates?.cancel() }
    func load() async {
        await refreshEntitlement()
        do {
            product = try await SafeReadRetry().run(operation: .productLoading) { try await Product.products(for: [Self.productID]) }.first { $0.type == .nonConsumable }
            if product == nil { message = String(localized: "The purchase is currently unavailable. Please try again later.") }
        } catch { report(error, operation: .productLoading) }
    }
    func refreshEntitlement() async {
        entitlementGeneration += 1
        let generation = entitlementGeneration
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.productType == .nonConsumable,
               transaction.revocationDate == nil { owned = true }
        }
        if generation == entitlementGeneration { isPro = owned }
    }
    private func accept(_ transaction: Transaction) {
        entitlementGeneration += 1
        isPro = transaction.productType == .nonConsumable && transaction.revocationDate == nil
    }
    func purchase() async {
        guard let product, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result, transaction.productID == Self.productID else {
                    message = String(localized: "Your purchase couldn’t be verified. Please try Restore Purchase."); return
                }
                accept(transaction)
                await transaction.finish()
                message = isPro ? String(localized: "HydroTone Pro is unlocked.") : String(localized: "Your purchase is being verified. Try Restore Purchase shortly.")
            case .userCancelled: break
            case .pending: message = String(localized: "Your purchase is pending approval. Pro will unlock when it’s approved.")
            @unknown default: message = String(localized: "The purchase couldn’t finish. Please try again.")
            }
        } catch StoreKitError.userCancelled { message = nil }
        catch { report(error, operation: .purchase) }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            message = isPro ? String(localized: "Purchase restored.") : String(localized: "No HydroTone Pro purchase was found for this Apple Account.")
        } catch { report(error, operation: .restore) }
    }
    private func report(_ error: Error, operation: Operation) {
        let failure = Failure.classify(error, operation: operation)
        Task { await diagnostics?.record(failure, operation: operation) }
        message = failure.kind == .cancelled ? nil : Failure(kind: .storeUnavailable, domain: failure.domain, code: failure.code).message
    }
}
