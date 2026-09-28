@testable import RepoPromptApp
import XCTest

/// Cancellation bursts must not rescan the demand queue once per cancelled request.
///
/// Every cancelled engine `demand` cancels itself individually, and owner cleanup cancels it
/// again. When each of those rescanned the whole queue, cancelling a large selection's codemap
/// demands cost O(cancellations × queued × active) of engine-actor time and starved the next
/// foreground demand, so `manage_selection` reply construction exceeded its 30-second contract.
final class WorkspaceCodemapBindingEngineCancellationSchedulingTests: XCTestCase {
    #if DEBUG
        func testCancellingAnUnknownOwnerDoesNotRescanTheQueue() async throws {
            let fixture = try CodemapStoreFixture(name: #function)
            addTeardownBlock { await fixture.shutdown() }
            let engine = try fixture.runtime().bindingEngine()
            let before = await engine.accounting().counters.queuedRequestSchedulingPasses

            for _ in 0 ..< 32 {
                let cancelled = await engine.cancel(owner: WorkspaceCodemapLiveDemandOwner())
                XCTAssertEqual(cancelled, 0)
            }

            let after = await engine.accounting().counters.queuedRequestSchedulingPasses
            XCTAssertEqual(after - before, 0, "A cancellation that releases nothing must not rescan the queue")
        }

        func testCancellingQueuedDemandsDoesNotRescanTheQueuePerRequest() async throws {
            let fileCount = 12
            var sources: [String: String] = [:]
            for index in 0 ..< fileCount {
                sources["Sources/File\(index).swift"] = "struct File\(index) { let value = \(index) }\n"
            }
            let repository = try ReviewGitRepositoryFixture(name: #function)
            let rootURL = try repository.makeRepository(named: "root", files: sources)
            // Every artifact build parks here, so whichever build holds the root's single
            // materialization slot keeps every demand queued behind it.
            let buildGate = TestReleaseFence(name: "codemap artifact build")
            let fixture = try CodemapStoreFixture(
                name: #function,
                enginePolicy: WorkspaceCodemapBindingEnginePolicy(
                    maximumConcurrentMaterializationCountPerRoot: 1
                ),
                beforeArtifactBuild: { _ in await buildGate.enterAndWait() }
            )
            let store = fixture.makeStore()
            let loaded = try await store.loadRoot(path: rootURL.path)
            addTeardownBlock {
                buildGate.release()
                await store.unloadRoot(id: loaded.id)
                await fixture.shutdown()
                repository.cleanup()
            }
            let engine = try fixture.runtime().bindingEngine()
            _ = await buildGate.waitUntilEntered(timeout: 30)

            let files = await store.files(inRoot: loaded.id)
            XCTAssertEqual(files.count, fileCount)
            var tickets: [WorkspaceCodemapArtifactDemandTicket] = []
            for file in files {
                let owned = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)
                guard case let .created(ticket) = owned.ownership else {
                    return XCTFail("Expected a fresh demand for \(file.standardizedRelativePath), got \(owned)")
                }
                tickets.append(ticket)
            }
            try await AsyncTestWait.waitUntil("all demands queued behind the gated build", timeout: 30) {
                await engine.accounting().queuedRequestCount == fileCount
            }
            let active = await engine.accounting().activeRequestCount
            XCTAssertEqual(active, 0, "The gated build must hold the only materialization slot")
            let before = await engine.accounting().counters.queuedRequestSchedulingPasses

            for ticket in tickets {
                let cancelled = await store.cancelCodemapArtifactDemand(ticket)
                XCTAssertTrue(cancelled)
            }
            try await AsyncTestWait.waitUntil("queued demands drained", timeout: 30) {
                await engine.accounting().queuedRequestCount == 0
            }
            // Let the per-demand cancellation handlers (unstructured tasks) reach the engine.
            let expectedCancellations = await engine.accounting().counters.cancellations
            XCTAssertGreaterThanOrEqual(expectedCancellations, UInt64(fileCount))
            for _ in 0 ..< 20 {
                await Task.yield()
                _ = await engine.accounting()
            }

            let after = await engine.accounting().counters.queuedRequestSchedulingPasses
            XCTAssertEqual(
                after - before,
                0,
                "Removing queued demands frees no admission capacity and must not rescan the queue"
            )
        }
    #endif
}
