import Foundation
import Observation
import StoreKit
import os

@MainActor @Observable
final class PurchaseStore {
    static let productID = "com.hydrotone.pro"
    private(set) var product: Product?
    private(set) var isPro = false
    private(set) var busy = false
    private var entitlementGeneration = 0
    var message: String?
    @ObservationIgnored nonisolated(unsafe) private var updates: Task<Void, Never>?
    init() {
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
    deinit { updates?.cancel() }
    func load() async {
        await refreshEntitlement()
        do {
            product = try await Product.products(for: [Self.productID]).first { $0.type == .nonConsumable }
            if product == nil { message = "The purchase is currently unavailable. Please try again later." }
        } catch { report(error) }
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
                    message = "Your purchase couldn’t be verified. Please try Restore Purchase."; return
                }
                accept(transaction)
                await transaction.finish()
                message = isPro ? "HydroTone Pro is unlocked." : "Your purchase is being verified. Try Restore Purchase shortly."
            case .userCancelled: break
            case .pending: message = "Your purchase is pending approval. Pro will unlock when it’s approved."
            @unknown default: message = "The purchase couldn’t finish. Please try again."
            }
        } catch StoreKitError.userCancelled { message = nil }
        catch { report(error) }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            message = isPro ? "Purchase restored." : "No HydroTone Pro purchase was found for this Apple Account."
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        #if DEBUG
        Logger(subsystem: "com.hydrotone.app", category: "store").error("\(String(reflecting: error), privacy: .public)")
        #endif
        message = "The App Store couldn’t complete this request. Check your connection and try again."
    }
}
