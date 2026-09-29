import CoreImage

/// The Core Image kernels in the .metal files. Xcode compiles them into default.metallib at build time.
/// Compiling Metal source at run time needs Core Image's headers on the device. On an iPhone with
/// iOS 27.0 that failed: "Could not find included source CIKernelMetalLibPrivate.h" (29 Sep 2026).
enum MetalKernels {
    static let library: Data? = Bundle.main.url(forResource: "default", withExtension: "metallib")
        .flatMap { try? Data(contentsOf: $0) }

    /// Nil when the library or the function is missing. Owners then use their fallback.
    static func color(_ name: String) -> CIColorKernel? {
        guard let library else { return nil }
        return (try? CIKernel(functionName: name, fromMetalLibraryData: library)) as? CIColorKernel
    }
}
