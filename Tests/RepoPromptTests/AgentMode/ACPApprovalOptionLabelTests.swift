@testable import RepoPromptApp
import XCTest

/// Covers the approval-card option labelling that `ACPAgentSessionController` applies to
/// agent-authored permission options.
///
/// These strings arrive from the agent and are joined with a newline to build the card's
/// option list, so anything that survives with a newline in it presents one option as two.
/// The suite exists because the surrounding permission tests all exercise option *selection*;
/// none of them reach the presentation path.
final class ACPApprovalOptionLabelTests: XCTestCase {
    private func label(_ raw: String) -> String? {
        ACPAgentSessionController.test_displayableOptionLabel(raw)
    }

    func testCollapsesNewlinesSoOneOptionCannotPresentAsTwo() {
        XCTAssertEqual(label("Allow\nDeny"), "Allow Deny")
        XCTAssertEqual(label("Allow\r\nonce"), "Allow once")
        XCTAssertEqual(label("Allow\u{2028}once"), "Allow once")
        for rendered in [label("Allow\nDeny"), label("Allow\r\nonce")] {
            let carriesSeparator = rendered?.unicodeScalars
                .contains { CharacterSet.newlines.contains($0) } ?? true
            XCTAssertFalse(
                carriesSeparator,
                "A label must never carry the separator used to join options."
            )
        }
    }

    func testTreatsValuesWithNothingVisibleAsAbsent() {
        XCTAssertNil(label(""))
        XCTAssertNil(label("   "))
        XCTAssertNil(label("\n\n"))
        XCTAssertNil(label("\u{200C}\u{200D}\u{2060}\u{202E}"))
    }

    /// Default-ignorable scalars render as nothing, so a label made only of them must fall
    /// back to the identifier rather than show a blank line.
    func testTreatsDefaultIgnorableScalarsAsNotVisible() {
        XCTAssertNil(label("\u{FE0F}"))
        XCTAssertNil(label("\u{034F}"))
        XCTAssertNil(label(" \u{FE0F}\u{034F}\u{200B} "))
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: "\u{FE0F}", optionID: "allow_once"),
            "allow_once"
        )
    }

    /// Bidi controls could visually reorder one option's wording to read like another, and
    /// other control characters render unpredictably, so neither reaches the card.
    func testStripsBidiControlsAndNeutralisesOtherControlCharacters() {
        XCTAssertEqual(label("Allow\u{202E}ecno"), "Allowecno")
        XCTAssertEqual(label("\u{2066}Allow\u{2069} once\u{202A}\u{202C}"), "Allow once")
        XCTAssertEqual(label("Allow\tonce"), "Allow once")
        XCTAssertEqual(label("Allow\u{8}once"), "Allow once")
        for raw in ["\u{202B}Allow\u{202D}", "\u{2067}Deny\u{2068}", "Allow\u{202E}"] {
            let rendered = label(raw) ?? ""
            XCTAssertFalse(
                rendered.unicodeScalars.contains { $0.properties.isBidiControl },
                "\(rendered.unicodeScalars.map { String($0.value, radix: 16) })"
            )
        }
        XCTAssertNil(label("\u{202E}\t\u{8}"))
    }

    func testKeepsEmojiSequencesIntactWhileSanitising() {
        XCTAssertEqual(label("\u{2764}\u{FE0F} Allow"), "\u{2764}\u{FE0F} Allow")
        XCTAssertEqual(label("\u{202E}👨‍👩‍👧‍👦 Allow"), "👨‍👩‍👧‍👦 Allow")
    }

    /// Emptiness is tested by looking for a visible scalar rather than by trimming invisible
    /// ones: the subdivision flags end in a run of format characters, and trimming those
    /// truncates the flag to a plain black flag.
    func testPreservesLabelsEndingInFormatCharacters() {
        let england = "Allow \u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        XCTAssertEqual(label(england), england)
    }

    func testPreservesOrdinaryAgentWording() {
        XCTAssertEqual(label("Allow for this session"), "Allow for this session")
        XCTAssertEqual(label("  Allow once  "), "Allow once")
        XCTAssertEqual(label("👨‍👩‍👧‍👦 Allow"), "👨‍👩‍👧‍👦 Allow")
        XCTAssertEqual(label("مرحبا"), "مرحبا")
    }

    // MARK: - Composition

    /// The sanitiser is only half the guarantee: the identifier fallback has to run through
    /// it too. Routing the name alone left the identifier able to reintroduce the newline.
    func testIdentifierFallbackIsSanitisedNotPassedThrough() {
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: nil, optionID: "allow\nalways"),
            "allow always"
        )
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: "   ", optionID: "allow\nonce"),
            "allow once"
        )
        // A non-ASCII separator too, so the identifier path is bound to the shared
        // sanitiser rather than to any handling that only knows about "\n".
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: nil, optionID: "allow\u{2028}once"),
            "allow once"
        )
    }

    func testPrefersTheAgentWordingOverTheIdentifier() {
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: "Allow once", optionID: "allow_once"),
            "Allow once"
        )
        XCTAssertEqual(
            ACPAgentSessionController.test_optionLabel(name: nil, optionID: "allow_once"),
            "allow_once"
        )
    }

    /// Blank lines would make distinct choices indistinguishable on the card, so an option
    /// with nothing displayable gets a fixed positional label instead.
    func testOptionsWithNothingDisplayableGetAPositionalFallback() {
        let lines = ACPAgentSessionController.test_optionLines([
            (name: "Allow once", optionID: "allow_once"),
            (name: "\u{200C}", optionID: "  "),
            (name: "\u{202E}\u{FE0F}", optionID: "\u{2066}\u{2069}"),
            (name: nil, optionID: "reject_once")
        ])
        XCTAssertEqual(lines, ["Allow once", "Option 2", "Option 3", "reject_once"])
        XCTAssertFalse(lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}
