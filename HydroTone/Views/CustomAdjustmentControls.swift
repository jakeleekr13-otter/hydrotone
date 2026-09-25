import SwiftUI

/// The five Custom sliders and Reset, shared by the editor and the batch screen.
/// Each slider is a position in -1...1, shown as -100...+100. Zero is the automatic result.
struct CustomAdjustmentControls: View {
    @Binding var adjustments: CustomAdjustments

    enum Control: CaseIterable, Identifiable {
        case brightness, contrast, saturation, clarity, temperature
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .brightness: "Brightness"
            case .contrast: "Contrast"
            case .saturation: "Saturation"
            case .clarity: "Clarity"
            case .temperature: "Temperature"
            }
        }
        var keyPath: WritableKeyPath<CustomAdjustments, Float> {
            switch self {
            case .brightness: \.brightness
            case .contrast: \.contrast
            case .saturation: \.saturation
            case .clarity: \.clarity
            case .temperature: \.temperature
            }
        }
    }

    /// "+30", "0" or "-30".
    nonisolated static func valueText(_ position: Float) -> String {
        let value = Int((min(1, max(-1, position.isFinite ? position : 0)) * 100).rounded())
        return value > 0 ? "+\(value)" : "\(value)"
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Control.allCases) { control in
                let text = Self.valueText(adjustments[keyPath: control.keyPath])
                VStack(spacing: 2) {
                    HStack {
                        Text(control.title)
                        Spacer()
                        Text(text).monospacedDigit().foregroundStyle(.secondary)
                    }.accessibilityHidden(true)
                    Slider(value: $adjustments[dynamicMember: control.keyPath], in: -1...1, step: 0.01)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text(control.title))
                        .accessibilityValue(Text(text))
                }
            }
            Button("Reset") { adjustments = .zero }
                .buttonStyle(.bordered).frame(minHeight: 44)
                .disabled(atZero)
        }
    }
    /// Slider steps can leave a tiny remainder near zero, so "all at zero" means every shown value is 0.
    private var atZero: Bool { Control.allCases.allSatisfy { Self.valueText(adjustments[keyPath: $0.keyPath]) == "0" } }
}
