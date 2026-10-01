import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AIChatImageAttachment {
    static let thumbnailMaxPixelSize = 384
    static let thumbnailMaxSourceDimension = 8192
    static let thumbnailMaxSourcePixelCount = 16_777_216

    /// Builds transcript thumbnails from request-scoped Oracle images off the
    /// caller's actor. Full bytes are never retained; each attachment stores a
    /// downscaled JPEG so session files stay small.
    static func thumbnails(from images: [AITransientImage]) async throws -> [AIChatImageAttachment] {
        try Task.checkCancellation()
        guard !images.isEmpty else { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            var attachments: [AIChatImageAttachment] = []
            for image in images {
                if let attachment = try autoreleasepool(invoking: { try thumbnail(from: image) }) {
                    attachments.append(attachment)
                }
            }
            try Task.checkCancellation()
            return attachments
        }
        return try await withTaskCancellationHandler {
            let attachments = try await worker.value
            try Task.checkCancellation()
            return attachments
        } onCancel: {
            worker.cancel()
        }
    }

    private static func sourceDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value.rounded(.towardZero) == value,
              let dimension = Int(exactly: value)
        else { return nil }
        return dimension
    }

    private static func thumbnail(from image: AITransientImage) throws -> AIChatImageAttachment? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = sourceDimension(properties[kCGImagePropertyPixelWidth]),
            let height = sourceDimension(properties[kCGImagePropertyPixelHeight]),
            width <= thumbnailMaxSourceDimension, height <= thumbnailMaxSourceDimension,
            width <= thumbnailMaxSourcePixelCount / height
        else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
        ] as CFDictionary),
            scaled.width > 0, scaled.height > 0,
            scaled.width <= thumbnailMaxPixelSize, scaled.height <= thumbnailMaxPixelSize
        else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        guard let opaque = flattenedOnWhite(scaled) else {
            try Task.checkCancellation()
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            try Task.checkCancellation()
            return nil
        }
        CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        try Task.checkCancellation()
        guard finalized else { return nil }

        return AIChatImageAttachment(
            mediaType: image.mediaType.rawValue,
            title: image.normalizedTitle,
            thumbnailData: output as Data
        )
    }

    /// JPEG has no alpha channel; matte transparent pixels onto white so
    /// transparent PNG/GIF/WebP screenshots do not render as black.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
