import AppKit
import RepoPromptDomainRuntime
import SwiftUI

enum AttachmentTileGeometry {
    /// Agent Mode composer strip: a 76x52 face with its title and caption beneath.
    case strip
    /// Oracle transcript chip: a bare 48x48 face. Title and caption move to the tooltip.
    case chip

    var faceSize: CGSize {
        switch self {
        case .strip: CGSize(width: 76, height: 52)
        case .chip: CGSize(width: 48, height: 48)
        }
    }

    var showsLabels: Bool {
        self == .strip
    }

    var faceCornerRadius: CGFloat {
        8
    }
}

/// Where a tile gets its preview. The tile decides whether one exists; callers only say where to look.
enum AttachmentTilePreview: Equatable {
    case none
    /// An already rendered preview image, such as the JPEG persisted with a transcript row.
    case rendered(Data)
    /// A file to render a preview from, off the main actor.
    case file(URL)
}

/// The one view that draws an attachment. Everything it shows comes from `AttachmentPresentation`.
struct AttachmentTile: View {
    let facts: AttachmentFacts
    let preview: AttachmentTilePreview
    let geometry: AttachmentTileGeometry
    /// The route the attachment is about to travel, so a tile can warn that it cannot be carried.
    var route: AttachmentRoute?
    var isDisabled = false
    var onDismiss: (() -> Void)?

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var loaded: LoadedPreview

    private enum LoadedPreview {
        case pending
        case image(NSImage)
        case missing

        var availability: AttachmentPreviewAvailability {
            switch self {
            case .pending: .pending
            case .image: .available
            case .missing: .unavailable
            }
        }
    }

    init(
        facts: AttachmentFacts,
        preview: AttachmentTilePreview,
        geometry: AttachmentTileGeometry,
        route: AttachmentRoute? = nil,
        isDisabled: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.facts = facts
        self.preview = preview
        self.geometry = geometry
        self.route = route
        self.isDisabled = isDisabled
        self.onDismiss = onDismiss
        _loaded = State(initialValue: Self.immediatePreview(facts: facts, preview: preview))
    }

    private var presentation: AttachmentPresentation {
        AttachmentPresentation.make(facts: facts, preview: loaded.availability, route: route)
    }

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        let presentation = presentation
        content(presentation)
            .task(id: preview) { await loadPreview() }
    }

    @ViewBuilder
    private func content(_ presentation: AttachmentPresentation) -> some View {
        switch geometry {
        case .strip:
            stripCard(presentation)
        case .chip:
            faceWithDismiss(presentation)
                .hoverTooltip(tooltip(for: presentation))
        }
    }

    private func stripCard(_ presentation: AttachmentPresentation) -> some View {
        let isRefused = presentation.refusalReason != nil
        let textWidth = fontPreset.scaledMetric(isRefused ? 150 : geometry.faceSize.width)
        return VStack(alignment: .leading, spacing: 4) {
            faceWithDismiss(presentation)

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isRefused, let caption = presentation.caption {
                    Text(caption)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: textWidth, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
        .hoverTooltip(tooltip(for: presentation))
    }

    private func faceWithDismiss(_ presentation: AttachmentPresentation) -> some View {
        ZStack(alignment: .topTrailing) {
            face(presentation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(isDisabled ? .gray : .secondary)
                        .background(Color(NSColor.windowBackgroundColor).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("Remove \(presentation.title)")
                .offset(x: 4, y: -4)
            }
        }
    }

    private func face(_ presentation: AttachmentPresentation) -> some View {
        let shape = RoundedRectangle(cornerRadius: geometry.faceCornerRadius)
        return faceFill(presentation.face)
            .frame(width: geometry.faceSize.width, height: geometry.faceSize.height)
            .overlay(alignment: .bottomLeading) {
                if let badge = presentation.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .padding(3)
                }
            }
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    presentation.refusalReason == nil ? Color.secondary.opacity(0.25) : Color.orange,
                    lineWidth: presentation.refusalReason == nil ? 1 : 2
                )
            )
    }

    @ViewBuilder
    private func faceFill(_ face: AttachmentFace) -> some View {
        switch face {
        case .preview:
            if case let .image(image) = loaded {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        case let .glyph(glyph):
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Image(systemName: glyph.systemSymbolName)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func tooltip(for presentation: AttachmentPresentation) -> String {
        [presentation.title, presentation.caption].compactMap(\.self).joined(separator: "\n")
    }

    private static func immediatePreview(facts: AttachmentFacts, preview: AttachmentTilePreview) -> LoadedPreview {
        guard facts.canHavePreview else { return .missing }
        switch preview {
        case .none:
            return .missing
        case let .rendered(data):
            return NSImage(data: data).map(LoadedPreview.image) ?? .missing
        case let .file(url):
            return AttachmentTilePreviewCache.shared.image(for: url, kind: facts.kind).map(LoadedPreview.image) ?? .pending
        }
    }

    private func loadPreview() async {
        let immediate = Self.immediatePreview(facts: facts, preview: preview)
        loaded = immediate
        guard case .pending = immediate, case let .file(url) = preview else { return }
        let image = await AttachmentTilePreviewCache.shared.render(url: url, kind: facts.kind)
        guard !Task.isCancelled else { return }
        loaded = image.map(LoadedPreview.image) ?? .missing
    }
}

private final class AttachmentTilePreviewCache: @unchecked Sendable {
    static let shared = AttachmentTilePreviewCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for url: URL, kind: AttachmentKind) -> NSImage? {
        cache.object(forKey: Self.key(url, kind))
    }

    func render(url: URL, kind: AttachmentKind) async -> NSImage? {
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try AttachmentPreviewRenderer.jpegData(fromFileAt: url, kind: kind) }
        }
        let jpeg = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard let jpeg, let image = NSImage(data: jpeg) else { return nil }
        cache.setObject(image, forKey: Self.key(url, kind))
        return image
    }

    private static func key(_ url: URL, _ kind: AttachmentKind) -> NSString {
        "\(kind.rawValue)|\(url.standardizedFileURL.path)" as NSString
    }
}
