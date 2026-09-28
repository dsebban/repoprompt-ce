@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunStateReactivationDiagnosticsTests: XCTestCase {
    override func tearDown() {
        AgentModePerfDiagnostics.clearRecentMetrics()
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(nil)
        super.tearDown()
    }

    /// The `agent_perf_metrics` line ring is flooded by chatty events long before a revived run is
    /// noticed, so reactivations are retained separately and survive that churn.
    func testReactivationFromTerminalStateSurvivesMetricLineChurn() throws {
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        AgentModePerfDiagnostics.clearRecentMetrics()
        let session = AgentTabSession(tabID: UUID())
        session.runState = .running
        session.runState = .completed

        session.runState = .running
        for index in 0 ..< 2000 {
            AgentModePerfDiagnostics.event("churn", fields: ["index": String(index)])
        }

        let snapshot = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 100)
        let reactivations = try XCTUnwrap(snapshot["run_state_reactivations"] as? [[String: String]])
        XCTAssertEqual(reactivations.count, 1)
        XCTAssertEqual(reactivations.first?["from"], AgentSessionRunState.completed.rawValue)
        XCTAssertEqual(reactivations.first?["to"], AgentSessionRunState.running.rawValue)
        XCTAssertFalse(reactivations.first?["callers", default: ""].isEmpty ?? true)
    }
}
