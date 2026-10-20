import Foundation

package struct AgentAttachmentStore {
    private static let attachmentsDirectoryName = "agent_attachments"

    package struct ImportResult {
        package let attachment: AgentFileAttachment
        package let fileURL: URL
    }

    package enum Error: LocalizedError {
        case invalidSourceURL
        case sourceIsNotFile
        case failedToCopy

        package var errorDescription: String? {
            switch self {
            case .invalidSourceURL:
                "Attachment source must be a local file URL."
            case .sourceIsNotFile:
                "Only files can be attached, not folders."
            case .failedToCopy:
                "Failed to import the selected file."
            }
        }
    }

    private let fileManager = FileManager.default

    package init() {}

    package static func managedStorageRootURL(for workspaceDirectory: URL) -> URL {
        workspaceDirectory
            .appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    /// Copies any regular file into managed storage and records what it is. The kind comes from the
    /// file's bytes through `AttachmentClassifier`, never from its extension.
    package func importFile(sourceURL: URL, workspaceDirectory: URL) throws -> ImportResult {
        let sourceURL = sourceURL.standardizedFileURL
        guard sourceURL.isFileURL else {
            throw Error.invalidSourceURL
        }
        guard let byteCount = regularFileByteCount(at: sourceURL) else {
            throw Error.sourceIsNotFile
        }

        let storageRoot = Self.managedStorageRootURL(for: workspaceDirectory)
        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let kind = classifiedKind(of: sourceURL, byteCount: byteCount)
        let destinationURL = storageRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension(for: sourceURL, kind: kind))

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw Error.failedToCopy
        }

        let attachment = AgentFileAttachment(
            source: .localFile(path: destinationURL.path),
            title: sourceURL.lastPathComponent,
            kind: kind,
            fileName: sourceURL.lastPathComponent,
            byteCount: byteCount
        )
        return ImportResult(attachment: attachment, fileURL: destinationURL)
    }

    package func clearConsumedLocalFiles(_ attachments: [AgentFileAttachment], workspaceDirectory: URL) {
        guard !attachments.isEmpty else { return }
        let storageRoot = Self.managedStorageRootURL(for: workspaceDirectory)
        let storagePrefix = storageRoot.path + "/"
        var localFilesToRemove: Set<URL> = []

        for attachment in attachments {
            guard case let .localFile(path) = attachment.source else { continue }
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard candidate.path.hasPrefix(storagePrefix) else { continue }
            localFilesToRemove.insert(candidate)
        }

        for fileURL in localFilesToRemove {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func regularFileByteCount(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true
        else { return nil }
        return values.fileSize ?? 0
    }

    /// Reads at most one request's worth of the file, so a very large file is named from its prefix
    /// instead of being loaded whole.
    private func classifiedKind(of url: URL, byteCount: Int) -> AttachmentKind {
        let probeLimit = OracleAttachmentLimits.production.maxBytesPerFile
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .binary }
        defer { try? handle.close() }
        let probe = (try? handle.read(upToCount: probeLimit)) ?? Data()
        return AttachmentClassifier.kind(ofProbe: probe, totalByteCount: max(byteCount, probe.count))
    }

    private func fileExtension(for sourceURL: URL, kind: AttachmentKind) -> String {
        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !ext.isEmpty {
            return ext
        }
        switch kind {
        case .image: return "png"
        case .pdf: return "pdf"
        case .text: return "txt"
        case .binary: return "bin"
        }
    }
}
