import SwiftUI

@main
struct HydroToneApp: App {
    @State private var purchases: PurchaseStore
    @State private var trial: TrialStore
    init() {
        _purchases = State(initialValue: PurchaseStore())
        var persistence = KeychainTrialPersistence()
        #if DEBUG
        // UI tests still exercise real Keychain persistence, isolated from a person's trial.
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-keychain=") }) {
            persistence = KeychainTrialPersistence(service: "com.hydrotone.uitests." + argument.dropFirst("--ui-test-keychain=".count))
        }
        #endif
        _trial = State(initialValue: TrialStore(persistence: persistence))
        TemporaryFiles.cleanPreviousSession()
    }
    var body: some Scene {
        WindowGroup {
            HomeView().preferredColorScheme(.dark).tint(.mint)
                .environment(purchases).environment(trial)
                .task { await purchases.load() }
        }
    }
}
