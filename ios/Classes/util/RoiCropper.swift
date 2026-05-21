// RoiCropper.swift
//
// Crops a CVPixelBuffer to a normalised ROI rectangle (0…1 coords,
// top-left origin) BEFORE the analyzer's resize-to-model-input step.
//
// Used by:
//   • ImageAnalyzer    (`analyze(file:)` / `pixelBuffer(for:region:)`)
//   • CameraFrameProcessor (live camera, ROI from CameraConfiguration)
//
// The crop is performed via CoreImage (`CIImage.cropped(to:)`) and
// rendered into a fresh BGRA CVPixelBuffer sized to the crop rect.
// CoreImage handles the source pixel format internally — same path the
// camera resize already uses, so no new framework imports.

import Foundation
import CoreImage
import CoreVideo

enum RoiCropper {

    /// Normalised ROI rectangle with top-left origin, all in `[0, 1]`.
    /// Out-of-range values are clamped; `nil` is returned if the rect
    /// collapses to zero area after clamping.
    struct Region {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        /// Build from a Dart-shaped dictionary
        /// `{x: Double, y: Double, width: Double, height: Double}`. Returns
        /// `nil` if any field is missing or non-numeric.
        static func from(map: [String: Any]?) -> Region? {
            guard let map = map,
                  let x = (map["x"] as? Double) ?? (map["x"] as? NSNumber)?.doubleValue,
                  let y = (map["y"] as? Double) ?? (map["y"] as? NSNumber)?.doubleValue,
                  let w = (map["width"]  as? Double) ?? (map["width"]  as? NSNumber)?.doubleValue,
                  let h = (map["height"] as? Double) ?? (map["height"] as? NSNumber)?.doubleValue
            else { return nil }
            return Region(x: x, y: y, width: w, height: h)
        }

        /// Apply the region to a source size, producing a pixel-space
        /// `CGRect` in **top-left** origin coordinates. Returns `nil` if
        /// the rect ends up empty after clamping to the source extent.
        func pixelRect(forSourceW sw: Int, sourceH sh: Int) -> CGRect? {
            guard sw > 0, sh > 0 else { return nil }
            // Clamp normalised coords to [0, 1] then derive pixel rect.
            let nx = max(0.0, min(1.0, x))
            let ny = max(0.0, min(1.0, y))
            let nw = max(0.0, min(1.0 - nx, width))
            let nh = max(0.0, min(1.0 - ny, height))
            let rect = CGRect(
                x: CGFloat(nx) * CGFloat(sw),
                y: CGFloat(ny) * CGFloat(sh),
                width:  CGFloat(nw) * CGFloat(sw),
                height: CGFloat(nh) * CGFloat(sh)
            )
            return (rect.width >= 1 && rect.height >= 1) ? rect : nil
        }
    }

    /// Shared CIContext — same caching policy CameraFrameProcessor uses.
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
    ])

    /// Crop the input pixel buffer to the supplied normalised region.
    /// Returns `nil` if the source dimensions are zero or the crop rect
    /// collapses. Output is a fresh BGRA CVPixelBuffer sized to the crop
    /// (no resize — the caller's analyzer / resize step takes the cropped
    /// buffer the rest of the way).
    static func crop(_ source: CVPixelBuffer, region: Region) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        guard let cropRectTopLeft = region.pixelRect(forSourceW: sw, sourceH: sh) else {
            return nil
        }

        // CoreImage uses bottom-left origin. Flip Y so the caller-facing
        // normalised ROI (top-left) lines up with the pixels CI samples.
        let ciCropRect = CGRect(
            x: cropRectTopLeft.origin.x,
            y: CGFloat(sh) - cropRectTopLeft.origin.y - cropRectTopLeft.height,
            width:  cropRectTopLeft.width,
            height: cropRectTopLeft.height
        )

        let cropped = CIImage(cvPixelBuffer: source)
            .cropped(to: ciCropRect)
            // Translate to origin so the destination buffer's (0,0)
            // matches the crop's top-left in the rendered output.
            .transformed(by: CGAffineTransform(
                translationX: -ciCropRect.origin.x,
                y: -ciCropRect.origin.y))

        let outW = Int(cropRectTopLeft.width.rounded())
        let outH = Int(cropRectTopLeft.height.rounded())
        guard outW > 0, outH > 0 else { return nil }

        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey:               outW,
            kCVPixelBufferHeightKey:              outH,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outW, outH,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dstBuffer = dst else { return nil }

        ciContext.render(cropped, to: dstBuffer)
        return dstBuffer
    }
}
