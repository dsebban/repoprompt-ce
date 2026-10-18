import Darwin
import Foundation
@testable import RepoPromptProcess
import XCTest

final class AppChildProcessRegistryTests: XCTestCase {
    func testAppExitKillsRegisteredGroupAndLeavesOtherChildrenAlone() async throws {
        let owned = try spawn("trap '' TERM; /bin/sleep 60 & echo $!; wait")
        defer { cleanup(owned) }
        let unrelated = try spawn("exec /bin/sleep 60")
        defer { cleanup(unrelated) }
        let registry = AppChildProcessRegistry()
        registry.register(pid: owned.pid)
        let descendantPID = try XCTUnwrap(
            Int32(String(decoding: owned.stdout.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(getpgid(descendantPID), owned.pid)

        registry.killAllForAppExit()

        let outcome = try await ProcessTermination.waitForTermination(
            pid: owned.pid,
            processGroupID: owned.processGroupID,
            timeout: 2
        )
        XCTAssertEqual(outcome.exitCode, 128 + SIGKILL, "The owner must still reap its child's SIGKILL status")
        XCTAssertEqual(kill(unrelated.pid, 0), 0, "Unregistered children must not be signaled")
        let descendantDeadline = ContinuousClock.now + .seconds(2)
        while kill(descendantPID, 0) == 0, ContinuousClock.now < descendantDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(descendantPID, 0), -1, "Registered descendants must not survive quit")
        _ = await ProcessTermination.terminateAndReap(pid: unrelated.pid, processGroupID: unrelated.processGroupID)
    }

    func testAppExitUnblocksCancellationIgnoringStdinWrite() async throws {
        let process = try spawn("exec /bin/sleep 60")
        defer { cleanup(process) }
        let registry = AppChildProcessRegistry()
        registry.register(pid: process.pid)
        let descriptor = try XCTUnwrap(process.stdinDescriptor)
        let enteredWrite = expectation(description: "entered blocking pipe write")
        let failedWrite = expectation(description: "blocked write released")
        let writer = Task.detached {
            enteredWrite.fulfill()
            do {
                try FDWriteSupport.writeAll(Data(repeating: 0x61, count: 1_000_000), to: descriptor)
                XCTFail("Unread pipe unexpectedly accepted the full frame")
            } catch {
                XCTAssertEqual(error as? FDWriteError, .brokenPipe(errno: EPIPE))
                failedWrite.fulfill()
            }
        }
        await fulfillment(of: [enteredWrite], timeout: 1)
        try? await Task.sleep(for: .milliseconds(30))
        writer.cancel()
        registry.killAllForAppExit()
        await fulfillment(of: [failedWrite], timeout: 1)
        let outcome = try await ProcessTermination.waitForTermination(
            pid: process.pid,
            processGroupID: process.processGroupID,
            timeout: 2
        )
        XCTAssertEqual(outcome.exitCode, 128 + SIGKILL)
    }

    func testChildRegisteredAfterAppExitIsKilledImmediately() async throws {
        let registry = AppChildProcessRegistry()
        registry.killAllForAppExit()
        let process = try spawn("exec /bin/sleep 60")
        defer { cleanup(process) }

        registry.register(pid: process.pid)

        let outcome = try await ProcessTermination.waitForTermination(
            pid: process.pid,
            processGroupID: process.processGroupID,
            timeout: 2
        )
        XCTAssertEqual(outcome.exitCode, 128 + SIGKILL)
    }

    private func cleanup(_ process: SpawnedProcess) {
        var info = siginfo_t()
        if let groupID = process.processGroupID,
           Darwin.waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
        {
            _ = ProcessTermination.signalProcessGroupOnly(processGroupID: groupID, signal: SIGKILL)
            var status: Int32 = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while Darwin.waitpid(process.pid, &status, WNOHANG) == 0,
                  ProcessInfo.processInfo.systemUptime < deadline
            {
                usleep(10000)
            }
        }
        process.stdin?.closeFile()
        process.stdout.closeFile()
        process.stderr.closeFile()
    }

    private func spawn(_ script: String) throws -> SpawnedProcess {
        try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil
        )
    }
}
