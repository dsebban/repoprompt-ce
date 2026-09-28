import MCP
@testable import RepoPromptApp
import XCTest

final class ContextBuilderReviewBaseTests: XCTestCase {
    func testReviewBaseDefaultsToHEADAndFollowsRequestedRefForReviews() throws {
        XCTAssertEqual(try ContextBuilderReviewBase.parse(from: nil, responseType: .review), "HEAD")
        XCTAssertEqual(try ContextBuilderReviewBase.parse(from: nil, responseType: nil), "HEAD")
        XCTAssertEqual(try ContextBuilderReviewBase.parse(from: .string(" origin/main "), responseType: .review), "origin/main")
        let requestedBase = try ContextBuilderReviewBase.parse(from: .string("origin/main"), responseType: .review)
        XCTAssertEqual(ReviewGitCompareIntent(base: requestedBase), .uncommittedMergeBase(symbolicBase: "origin/main"))
    }

    func testReviewBaseRejectsNonReviewRunsAndNonRefValues() {
        let rejected: [(Value, ContextBuilderResponseType?)] = [
            (.string("main"), .plan),
            (.string("main"), nil),
            (.string("  "), .review),
            (.string("mergebase:origin/main"), .review),
            (.string("--output=x"), .review),
            (.string("origin main"), .review),
            (.int(1), .review)
        ]
        for (value, responseType) in rejected {
            XCTAssertThrowsError(
                try ContextBuilderReviewBase.parse(from: value, responseType: responseType),
                "\(value) \(String(describing: responseType))"
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("review_base"), error.localizedDescription)
            }
        }
    }

    func testCanonicalContextBuilderSchemaAdvertisesReviewBase() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.contextBuilder))
        let properties = try XCTUnwrap(definition.inputSchema.objectValue?["properties"]?.objectValue)
        let reviewBase = try XCTUnwrap(properties["review_base"]?.objectValue)
        XCTAssertEqual(reviewBase["type"]?.stringValue, "string")
        XCTAssertTrue(definition.description.contains("review_base"))
    }
}
