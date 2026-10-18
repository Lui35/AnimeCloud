import CoreGraphics
import CoreVideo
import Foundation

public extension Anime4KInterpolator {
    func enhance(image: CGImage) throws -> CGImage {
        let input = try cgImageToPixelBuffer(image)
        let output = try enhance(pixelBuffer: input)
        return try pixelBufferToCGImage(output)
    }
}

private func cgImageToPixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
    let width = image.width
    let height = image.height
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    var buffer: CVPixelBuffer?
    let err = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &buffer
    )
    guard err == kCVReturnSuccess, let buffer else {
        throw Anime4KError.processingFailed("CVPixelBufferCreate failed: \(err)")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw Anime4KError.processingFailed("CVPixelBufferGetBaseAddress failed")
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw Anime4KError.processingFailed("CGContext init failed")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

private func pixelBufferToCGImage(_ buffer: CVPixelBuffer) throws -> CGImage {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw Anime4KError.processingFailed("CVPixelBufferGetBaseAddress failed")
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw Anime4KError.processingFailed("CGContext init failed")
    }
    guard let image = context.makeImage() else {
        throw Anime4KError.processingFailed("CGContext.makeImage failed")
    }
    return image
}
