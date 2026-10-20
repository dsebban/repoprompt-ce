import Foundation

/// What an attached file is, resolved from its bytes by `AttachmentClassifier` and never from its extension.
package enum AttachmentKind: String, Codable, CaseIterable {
    /// PNG, JPEG, GIF, or WebP. Formats no transport accepts are converted before they reach this kind.
    case image
    case pdf
    /// Strict UTF-8 with no NUL byte in the first 8 KiB.
    case text
    case binary
}

/// Image formats every transport can carry. Raw values are the MIME strings placed on the wire.
package enum ImageMediaType: String, Equatable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webp = "image/webp"
}

/// Attachment bytes paired with the only kind they can have, so a kind can never disagree with its content.
package enum AttachmentPayload: Equatable {
    case image(ImageMediaType, Data)
    case pdf(Data)
    /// Decoded text plus the original bytes it was decoded from.
    case text(String, Data)
    case binary(Data)

    package var kind: AttachmentKind {
        switch self {
        case .image: .image
        case .pdf: .pdf
        case .text: .text
        case .binary: .binary
        }
    }

    /// Size of the original file content in bytes.
    package var byteCount: Int {
        switch self {
        case let .image(_, data), let .pdf(data), let .text(_, data), let .binary(data): data.count
        }
    }
}
