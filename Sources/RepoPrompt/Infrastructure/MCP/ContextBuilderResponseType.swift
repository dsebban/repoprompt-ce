import Foundation
import MCP

enum ContextBuilderResponseType: String {
    case plan
    case question
    case review
    case clarify

    static func parse(from value: Value?) throws -> ContextBuilderResponseType? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let parsed = ContextBuilderResponseType(rawValue: raw.lowercased()) else {
            throw MCPError.invalidParams("Invalid response_type: \(raw)")
        }
        return parsed
    }

    var wantsResponse: Bool {
        switch self {
        case .plan, .question, .review:
            true
        case .clarify:
            false
        }
    }

    var generationLabel: String? {
        switch self {
        case .plan:
            "plan"
        case .question:
            "question"
        case .review:
            "review"
        case .clarify:
            nil
        }
    }

    func supportsPresetMode(_ preset: ModelPreset) -> Bool {
        switch self {
        case .plan:
            preset.supportedModes?.plan ?? true
        case .review:
            preset.supportedModes?.review ?? true
        case .question:
            preset.supportedModes?.chat ?? true
        case .clarify:
            false
        }
    }
}

/// The Git ref a review Context Builder run compares against. The final review package diffs the
/// selected files from `merge-base(HEAD, review_base)` to the working tree, so a branch base
/// includes committed branch changes; the default `HEAD` covers uncommitted changes only. The
/// repository itself is still elected by the final selection.
enum ContextBuilderReviewBase {
    static let uncommitted = "HEAD"

    static func parse(from value: Value?, responseType: ContextBuilderResponseType?) throws -> String {
        guard let value, value != .null else { return uncommitted }
        guard responseType == .review else {
            throw MCPError.invalidParams("review_base requires response_type 'review'.")
        }
        guard let raw = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.hasPrefix("-"),
              !raw.contains(":"),
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            throw MCPError.invalidParams(
                "review_base must be a Git branch or ref such as 'origin/main' (not a git compare spec)."
            )
        }
        return raw
    }
}
