import CoreVideo
import Foundation

/// Tiny `@unchecked Sendable` wrapper around `CVPixelBuffer`.
///
/// `CVPixelBuffer` (aka `CVBuffer`) is reference-typed Core Video media but
/// Apple does not mark it `Sendable` — moving one across a Task / actor
/// boundary trips Swift 6 strict-concurrency warnings.
///
/// In our code the buffers are produced by pipelines that never mutate them
/// after creation (CoreML inference inputs, video-frame snapshots), so
/// crossing isolation domains is safe in practice. This wrapper makes that
/// promise explicit and confines the `@unchecked` annotation to one place
/// instead of sprinkling it across every TaskGroup return type.
struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

extension Array where Element == CVPixelBuffer {
    /// Convenience: wrap each element so the array crosses an `@Sendable`
    /// boundary cleanly. The underlying buffers are reference-typed and
    /// shared — no copy.
    var sendableWrapped: [SendablePixelBuffer] {
        map(SendablePixelBuffer.init)
    }
}

extension Array where Element == SendablePixelBuffer {
    /// Inverse of `sendableWrapped`.
    var unwrapped: [CVPixelBuffer] {
        map(\.value)
    }
}
