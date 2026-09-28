@testable import RepoPromptApp
import XCTest

/// A presentation that gives up waiting must release its still-pending demand tickets together.
///
/// Each ticket's cancellation awaits engine cleanup. Releasing them one by one serialized every
/// cleanup behind a busy engine actor: a 41-file `manage_selection` reply with ~560 pending
/// auto-codemaps spent ~8 s after its 10 s presentation budget and exceeded the 30-second contract.
final class WorkspaceCodemapPresentationReleaseConcurrencyTests: XCTestCase {
    #if DEBUG
        func testPendingDemandTicketsAreReleasedConcurrently() async throws {
            let fileCount = 8
            var sources: [String: String] = [:]
            for index in 0 ..< fileCount {
                sources["Sources/File\(index).swift"] = "struct File\(index) { let value = \(index) }\n"
            }
            let repository = try ReviewGitRepositoryFixture(name: #function)
            let rootURL = try repository.makeRepository(named: "root", files: sources)
            // Builds never finish during the presentation, so every demand is still pending
            // when the budget expires and must be released.
            let buildGate = TestReleaseFence(name: "codemap artifact build")
            let fixture = try CodemapStoreFixture(
                name: #function,
                beforeArtifactBuild: { _ in await buildGate.enterAndWait() }
            )
            let cleanups = CleanupConcurrencyProbe()
            let store = fixture.makeStore(codemapCancellationCleanupHook: { _ in
                await cleanups.run { try? await Task.sleep(for: .milliseconds(100)) }
            })
            let loaded = try await store.loadRoot(path: rootURL.path)
            addTeardownBlock {
                buildGate.release()
                await store.unloadRoot(id: loaded.id)
                await fixture.shutdown()
                repository.cleanup()
            }
            let files = await store.files(inRoot: loaded.id)
            XCTAssertEqual(files.count, fileCount)

            let presentation = try await WorkspaceCodemapPresentationCoordinator(
                store: store,
                policy: WorkspaceCodemapPresentationRequestPolicy(maximumTotalWait: .milliseconds(300))
            ).presentation(
                for: .exact(fileIDs: files.map(\.id), completeRootSet: false),
                rootScope: .allLoaded
            )

            XCTAssertTrue(presentation.orderedEntries.isEmpty, "Gated builds must leave every codemap pending")
            let snapshot = await cleanups.snapshot()
            XCTAssertGreaterThanOrEqual(snapshot.completed, 2, "Release must finish each released ticket's cleanup")
            XCTAssertGreaterThan(
                snapshot.maximumInFlight,
                1,
                "Pending tickets must be released concurrently, not serialized behind each cleanup"
            )
        }
    #endif
}

private actor CleanupConcurrencyProbe {
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var completed = 0

    func run(_ body: @Sendable () async -> Void) async {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        await body()
        inFlight -= 1
        completed += 1
    }

    func snapshot() -> (maximumInFlight: Int, completed: Int) {
        (maximumInFlight, completed)
    }
}
