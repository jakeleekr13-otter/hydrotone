import SwiftUI

struct ProView: View {
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "water.waves").font(.system(size: 44)).foregroundStyle(.mint).accessibilityHidden(true)
                    Text("HydroTone Pro").font(.largeTitle.bold())
                    Text("One-time purchase. Every dive.").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Unlimited photo exports", systemImage: "photo")
                        Label(String(localized: "Batch correct up to \(BatchModel.maxPhotos) photos"), systemImage: "square.grid.2x2")
                        Label("Full-length video exports", systemImage: "video")
                        Label("4K export", systemImage: "4k.tv")
                        Label("HDR export where supported", systemImage: "sun.max")
                    }
                    if purchases.isPro {
                        Label("Pro is unlocked", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
                    } else if let product = purchases.product {
                        Button(String(localized: "Buy Pro · \(product.displayPrice)")) { Task { await purchases.purchase() } }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    } else {
                        Text("Purchase is currently unavailable.").foregroundStyle(.secondary)
                        Button("Retry") { Task { await purchases.load() } }
                    }
                    Button("Restore Purchase") { Task { await purchases.restore() } }.frame(minHeight: 44)
                    if purchases.busy { ProgressView() }
                    if let message = purchases.message { Text(message).font(.callout).accessibilityAddTraits(.updatesFrequently) }
                    Text("All processing stays on your iPhone. No account or subscription.").font(.footnote).foregroundStyle(.secondary)
                }.padding(28).disabled(purchases.busy)
            }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.task { await purchases.load() }
    }
}
