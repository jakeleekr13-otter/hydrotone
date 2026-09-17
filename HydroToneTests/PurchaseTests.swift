import XCTest
import StoreKit
import StoreKitTest
@testable import HydroTone

@MainActor
final class PurchaseTests: XCTestCase {
    func waitForOwnership(_ expected: Bool, store: PurchaseStore) async {
        for _ in 0..<60 {
            await store.refreshEntitlement()
            if store.isPro == expected { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    func testCancelledAndFailedPurchasesDoNotGrantPro() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HydroTone", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState(); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let store = PurchaseStore(); await store.load()
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await store.purchase()
        XCTAssertFalse(store.isPro)
        try await session.setSimulatedError(.generic(.notAvailableInStorefront), forAPI: .purchase)
        await store.purchase()
        XCTAssertFalse(store.isPro)
        XCTAssertNotNil(store.message)
    }
    func testVerifiedPurchaseRestoreRefundAndPendingApproval() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HydroTone", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let store = PurchaseStore()
        await store.load()
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.product?.id, PurchaseStore.productID)
        await store.purchase()
        XCTAssertTrue(store.isPro)
        let relaunched = PurchaseStore()
        await relaunched.refreshEntitlement()
        XCTAssertTrue(relaunched.isPro)
        await relaunched.restore()
        XCTAssertTrue(relaunched.isPro)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await waitForOwnership(false, store: store)
        XCTAssertFalse(store.isPro)
        session.clearTransactions()
        session.askToBuyEnabled = true
        await store.purchase()
        XCTAssertFalse(store.isPro)
        XCTAssertTrue(store.message?.contains("pending") == true)
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        await waitForOwnership(true, store: store)
        XCTAssertTrue(store.isPro)
    }
}
