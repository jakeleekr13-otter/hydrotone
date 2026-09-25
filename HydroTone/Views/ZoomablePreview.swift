import SwiftUI

/// Pinch-to-zoom state for a still preview. Pure, so the limits can be unit tested.
struct PreviewZoom: Equatable {
    static let maximum: CGFloat = 4
    static let doubleTapScale: CGFloat = 2.5
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var isZoomed: Bool { scale > 1.01 }

    /// Keeps the scale in 1...maximum and the image edges outside the frame, so no gap opens.
    func clamped(content: CGSize, container: CGSize) -> PreviewZoom {
        let s = min(Self.maximum, max(1, scale.isFinite ? scale : 1))
        let limitX = max(0, (content.width * s - container.width) / 2)
        let limitY = max(0, (content.height * s - container.height) / 2)
        func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat { value.isFinite ? min(limit, max(-limit, value)) : 0 }
        return PreviewZoom(scale: s, offset: CGSize(width: clamp(offset.width, limitX), height: clamp(offset.height, limitY)))
    }

    /// Size of an image with `pixels` fitted inside `container` (aspect fit).
    static func fitted(_ pixels: CGSize, in container: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let s = min(container.width / pixels.width, container.height / pixels.height)
        return CGSize(width: pixels.width * s, height: pixels.height * s)
    }
}

/// A photo preview that zooms with a pinch or a double tap and pans while zoomed.
/// The zoom state is owned by the caller, so swapping the image (Compare, a sharper render) keeps it.
struct ZoomablePreview: View {
    let image: CGImage
    @Binding var zoom: PreviewZoom
    var onZoomIn: () -> Void = {}
    @State private var base = PreviewZoom()

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let content = PreviewZoom.fitted(CGSize(width: image.width, height: image.height), in: container)
            Image(decorative: image, scale: 1).resizable()
                .frame(width: content.width, height: content.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .frame(width: container.width, height: container.height)
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        zoom = PreviewZoom(scale: base.scale * value.magnification, offset: zoom.offset)
                            .clamped(content: content, container: container)
                    }
                    .onEnded { _ in finish() }
                    .simultaneously(with: DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            // Panning only makes sense while zoomed; at 1x the image already fits.
                            guard zoom.isZoomed else { return }
                            let moved = CGSize(width: base.offset.width + value.translation.width,
                                               height: base.offset.height + value.translation.height)
                            zoom = PreviewZoom(scale: zoom.scale, offset: moved).clamped(content: content, container: container)
                        }
                        .onEnded { _ in finish() }))
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        zoom = zoom.isZoomed ? PreviewZoom()
                            : PreviewZoom(scale: PreviewZoom.doubleTapScale).clamped(content: content, container: container)
                    }
                    finish()
                }
        }
        .accessibilityElement()
        .accessibilityLabel("Photo preview")
        .accessibilityValue(Text("\(Int((zoom.scale * 100).rounded()))%"))
        .accessibilityHint("Pinch or double-tap to zoom.")
        .accessibilityZoomAction { action in
            let step: CGFloat = action.direction == .zoomIn ? 1.5 : 1 / 1.5
            // Offset resets to the centre, which is always inside the limits.
            zoom = PreviewZoom(scale: zoom.scale * step).clamped(content: .zero, container: .zero)
            finish()
        }
    }

    private func finish() {
        base = zoom
        if zoom.isZoomed { onZoomIn() }
    }
}
