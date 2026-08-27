import XCTest
@testable import MirrorBridge

final class FakeADB: ADBClient, @unchecked Sendable {
    var startServerResult = CommandResult(exitCode: 0, stdout: "", stderr: "")
    var pairResult = CommandResult(exitCode: 0, stdout: "paired", stderr: "")
    var connectResult = CommandResult(exitCode: 0, stdout: "connected", stderr: "")
    var discoveryResult = DiscoveryResult(
        devices: [],
        command: CommandResult(exitCode: 0, stdout: "", stderr: "")
    )
    var pairCalls: [(address: String, code: String)] = []
    var connectCalls: [String] = []
    var discoverCalls = 0
    var startServerCalls = 0
    var waitForStartServer = false
    var waitForConnect = false
    private var pendingConnect: CheckedContinuation<CommandResult, Never>?
    private var pendingStartServer: CheckedContinuation<CommandResult, Never>?

    func startServer() async -> CommandResult {
        startServerCalls += 1
        if waitForStartServer {
            return await withCheckedContinuation { continuation in
                pendingStartServer = continuation
            }
        }
        return startServerResult
    }

    func pair(address: String, code: String) async -> CommandResult {
        pairCalls.append((address, code))
        return pairResult
    }

    func connect(endpoint: String) async -> CommandResult {
        connectCalls.append(endpoint)
        if waitForConnect {
            return await withCheckedContinuation { continuation in
                pendingConnect = continuation
            }
        }
        return connectResult
    }

    func discover() async -> DiscoveryResult {
        discoverCalls += 1
        return discoveryResult
    }

    func finishPendingConnect(with result: CommandResult) {
        pendingConnect?.resume(returning: result)
        pendingConnect = nil
    }

    func finishPendingStartServer(with result: CommandResult) {
        pendingStartServer?.resume(returning: result)
        pendingStartServer = nil
    }
}

final class FakeScrcpy: ScrcpyClient, @unchecked Sendable {
    struct StartCall {
        let endpoint: String
        let onExit: (Int32) -> Void
    }

    var startError: Error?
    var startCalls: [String] = []
    var stopCalls = 0
    private(set) var startCallDetails: [StartCall] = []
    private var exitedSessions = Set<Int>()

    var isRunning: Bool {
        startCallDetails.indices.contains { !exitedSessions.contains($0) }
    }

    func start(
        endpoint: String,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        if let startError {
            throw startError
        }
        startCalls.append(endpoint)
        startCallDetails.append(StartCall(endpoint: endpoint, onExit: onExit))
    }

    func stop() {
        stopCalls += 1
    }

    func triggerExit(at index: Int, status: Int32) {
        exitedSessions.insert(index)
        startCallDetails[index].onExit(status)
    }
}

final class SequenceToolLocator: ToolLocating {
    var paths: [ToolPaths]
    private(set) var calls = 0

    init(paths: [ToolPaths]) {
        self.paths = paths
    }

    func locate() -> ToolPaths {
        let path = paths[min(calls, paths.count - 1)]
        calls += 1
        return path
    }
}

enum TestError: Error {
    case scrcpyUnavailable
}

@MainActor
final class MirrorBridgeTests: XCTestCase {
    func testMissingToolsAreDistinguished() {
        let missingADB = AppModel(adb: nil, scrcpy: FakeScrcpy(), startsRefreshLoop: false)
        XCTAssertEqual(missingADB.toolStatus, .missingADB)

        let missingScrcpy = AppModel(adb: FakeADB(), scrcpy: nil, startsRefreshLoop: false)
        XCTAssertEqual(missingScrcpy.toolStatus, .missingScrcpy)

        let missingBoth = AppModel(adb: nil, scrcpy: nil, startsRefreshLoop: false)
        XCTAssertEqual(missingBoth.toolStatus, .missingBoth)
    }

    func testToolRefreshRecoversFromMissingScrcpyWithoutRestarting() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        adb.discoveryResult = DiscoveryResult(
            devices: [DiscoveredDevice(endpoint: "192.168.1.7:41231", serviceName: "pixel")],
            command: CommandResult(exitCode: 0, stdout: "", stderr: "")
        )
        let locator = SequenceToolLocator(paths: [
            ToolPaths(adbURL: URL(fileURLWithPath: "/tools/adb"), scrcpyURL: nil, processEnvironment: [:]),
            ToolPaths(
                adbURL: URL(fileURLWithPath: "/tools/adb"),
                scrcpyURL: URL(fileURLWithPath: "/tools/scrcpy"),
                processEnvironment: [:]
            )
        ])
        let model = AppModel(
            toolLocator: locator,
            adbFactory: { _, _ in adb },
            scrcpyFactory: { _, _ in scrcpy },
            startsRefreshLoop: false
        )

        XCTAssertEqual(model.toolStatus, .missingScrcpy)
        model.refreshNow()

        let recovered = await eventually { model.toolStatus == .ready && model.devices.count == 1 }
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.selectedEndpoint, "192.168.1.7:41231")
        XCTAssertEqual(model.state, .discovered)
        XCTAssertEqual(locator.calls, 2)
    }

    func testToolRefreshRecoversFromMissingADBWithoutRestarting() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        let locator = SequenceToolLocator(paths: [
            ToolPaths(
                adbURL: nil,
                scrcpyURL: URL(fileURLWithPath: "/tools/scrcpy"),
                processEnvironment: [:]
            ),
            ToolPaths(
                adbURL: URL(fileURLWithPath: "/tools/adb"),
                scrcpyURL: URL(fileURLWithPath: "/tools/scrcpy"),
                processEnvironment: [:]
            )
        ])
        let model = AppModel(
            toolLocator: locator,
            adbFactory: { _, _ in adb },
            scrcpyFactory: { _, _ in scrcpy },
            startsRefreshLoop: false
        )

        XCTAssertEqual(model.toolStatus, .missingADB)
        model.refreshNow()

        let recovered = await eventually { model.toolStatus == .ready && model.devices.count == 1 }
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.state, .discovered)
    }

    func testMDNSParserKeepsDynamicMultiDeviceEndpointsAndDropsDuplicates() {
        let output = """
        List of discovered mdns services
        pixel-1 _adb-tls-connect._tcp 192.168.1.7:41231
        pixel-1 _adb-tls-connect._tcp 192.168.1.7:41231
        tablet _adb-tls-connect._tcp 192.168.1.8:39877
        pairing-only _adb-tls-pairing._tcp 192.168.1.9:37001
        malformed _adb-tls-connect._tcp
        """

        XCTAssertEqual(
            ADBService.parseMDNS(output),
            [
                DiscoveredDevice(endpoint: "192.168.1.7:41231", serviceName: "pixel-1"),
                DiscoveredDevice(endpoint: "192.168.1.8:39877", serviceName: "tablet")
            ]
        )
    }

    func testDiscoveryNoResultsAndCommandFailureHaveDifferentRecoveryStates() async {
        let adb = FakeADB()
        let model = AppModel(adb: adb, scrcpy: FakeScrcpy(), startsRefreshLoop: false)

        adb.discoveryResult = DiscoveryResult(
            devices: [],
            command: CommandResult(exitCode: 0, stdout: "", stderr: "")
        )
        model.refreshNow()
        let waiting = await eventually { model.state == .waiting }
        XCTAssertTrue(waiting)
        XCTAssertTrue(model.statusMessage.contains("等待"))

        adb.discoveryResult = DiscoveryResult(
            devices: [],
            command: CommandResult(exitCode: 1, stdout: "", stderr: "mdns unavailable")
        )
        model.refreshNow()
        let failed = await eventually { model.state == .error }
        XCTAssertTrue(failed)
        XCTAssertTrue(model.statusMessage.contains("mdns unavailable"))
    }

    func testDiscoveryFailurePreservesTheLastSuccessfulInventory() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)

        adb.discoveryResult = DiscoveryResult(
            devices: [],
            command: CommandResult(exitCode: 1, stdout: "", stderr: "mdns unavailable")
        )
        model.refreshNow()
        let failed = await eventually { model.state == .error }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(model.selectedEndpoint, "192.168.1.7:41231")
    }

    func testADBServerFailureBlocksDiscoveryUntilAHealthyRetry() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        adb.startServerResult = CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "adb server failed"
        )
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()

        let failed = await eventually { model.state == .error && !model.isBusy }
        XCTAssertTrue(failed)
        XCTAssertEqual(adb.startServerCalls, 1)
        XCTAssertEqual(adb.discoverCalls, 0)
        XCTAssertTrue(model.statusMessage.contains("server"))

        adb.startServerResult = CommandResult(exitCode: 0, stdout: "", stderr: "")
        model.refreshNow()

        let recovered = await eventually { adb.discoverCalls == 1 && model.devices.count == 1 }
        XCTAssertTrue(recovered)
        XCTAssertEqual(adb.startServerCalls, 2)
    }

    func testADBServerStartupInFlightBlocksOtherADBOperations() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        adb.waitForStartServer = true
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let starting = await eventually { adb.startServerCalls == 1 }
        XCTAssertTrue(starting)

        model.refreshNow()
        model.pairingAddress = "192.168.1.7:37001"
        model.pairingCode = "pairing-\(UUID().uuidString)"
        model.pair()
        model.connectAndMirror()
        await Task.yield()

        XCTAssertEqual(adb.startServerCalls, 1)
        XCTAssertEqual(adb.discoverCalls, 0)
        XCTAssertTrue(adb.pairCalls.isEmpty)
        XCTAssertTrue(adb.connectCalls.isEmpty)

        adb.finishPendingStartServer(with: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        let discovered = await eventually { adb.discoverCalls == 1 && model.devices.count == 1 }
        XCTAssertTrue(discovered)
    }

    func testCancellingADBServerStartupWaitsForItsResultAndDoesNotDiscover() async {
        let adb = FakeADB()
        let model = AppModel(adb: adb, scrcpy: FakeScrcpy(), startsRefreshLoop: false)
        adb.waitForStartServer = true

        model.refreshNow()
        let starting = await eventually { adb.startServerCalls == 1 }
        XCTAssertTrue(starting)

        model.stopMirror()
        XCTAssertTrue(model.isBusy)
        adb.finishPendingStartServer(with: CommandResult(exitCode: 0, stdout: "", stderr: ""))

        let cancelled = await eventually { !model.isBusy }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(adb.discoverCalls, 0)
    }

    func testPairingIsExplicitAndClearsCodeWithoutLoggingIt() async {
        let adb = FakeADB()
        let pairingCode = "pairing-\(UUID().uuidString)"
        adb.pairResult = CommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "invalid pairing code \(pairingCode)"
        )
        let model = AppModel(adb: adb, scrcpy: FakeScrcpy(), startsRefreshLoop: false)
        model.refreshNow()
        let serverReady = await eventually { adb.discoverCalls == 1 }
        XCTAssertTrue(serverReady)
        model.pairingAddress = "192.168.1.7:37001"
        model.pairingCode = pairingCode

        model.pair()

        XCTAssertEqual(model.pairingCode, "")
        let paired = await eventually { adb.pairCalls.count == 1 && !model.isBusy }
        XCTAssertTrue(paired)
        XCTAssertEqual(adb.pairCalls.first?.address, "192.168.1.7:37001")
        XCTAssertEqual(adb.pairCalls.first?.code, pairingCode)
        XCTAssertFalse(model.logText.contains(pairingCode))

        model.refreshNow()
        let discoveredAfterPair = await eventually { adb.discoverCalls > 0 }
        XCTAssertTrue(discoveredAfterPair)
        XCTAssertEqual(adb.pairCalls.count, 1)
    }

    func testSuccessfulFlowStopsAndReconnectsWithoutPairingAgain() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let mirroring = await eventually { model.state == .mirroring }
        XCTAssertTrue(mirroring)
        XCTAssertEqual(adb.connectCalls, ["192.168.1.7:41231"])
        XCTAssertEqual(scrcpy.startCalls, ["192.168.1.7:41231"])
        XCTAssertEqual(adb.pairCalls.count, 0)

        model.stopMirror()
        XCTAssertTrue(model.isMirroring)
        XCTAssertEqual(model.state, .stopping)
        XCTAssertEqual(scrcpy.stopCalls, 1)

        model.connectAndMirror()
        await Task.yield()
        XCTAssertEqual(adb.connectCalls.count, 1)
        XCTAssertEqual(scrcpy.startCalls.count, 1)

        scrcpy.triggerExit(at: 0, status: 0)
        let stopped = await eventually { !model.isMirroring }
        XCTAssertTrue(stopped)
        XCTAssertEqual(model.state, .connected)

        model.stopMirror()
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(scrcpy.stopCalls, 1)

        model.connectAndMirror()
        let reconnected = await eventually { model.state == .mirroring }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(adb.connectCalls.count, 2)
        XCTAssertEqual(adb.pairCalls.count, 0)
    }

    func testStopIsIdempotentAndLateExitCannotClearTheNextSession() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let mirroring = await eventually { model.state == .mirroring }
        XCTAssertTrue(mirroring)

        model.stopMirror()
        model.stopMirror()
        XCTAssertEqual(scrcpy.stopCalls, 1)
        XCTAssertTrue(model.isMirroring)

        scrcpy.triggerExit(at: 0, status: 0)
        let stopped = await eventually { model.state == .connected }
        XCTAssertTrue(stopped)
        model.connectAndMirror()
        let reconnected = await eventually {
            model.state == .mirroring && scrcpy.startCallDetails.count == 2
        }
        XCTAssertTrue(reconnected)

        scrcpy.triggerExit(at: 0, status: 9)
        await Task.yield()
        XCTAssertTrue(model.isMirroring)
        XCTAssertEqual(model.state, .mirroring)

        scrcpy.triggerExit(at: 1, status: 9)
        let exited = await eventually { !model.isMirroring && model.state == .connected }
        XCTAssertTrue(exited)
    }

    func testUnconfirmedStopKeepsTheSessionSlotReserved() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        let model = AppModel(
            adb: adb,
            scrcpy: scrcpy,
            startsRefreshLoop: false,
            stopConfirmationTimeout: 0.01
        )

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let mirroring = await eventually { model.state == .mirroring }
        XCTAssertTrue(mirroring)

        model.stopMirror()
        let unconfirmed = await eventually { model.state == .stopUnconfirmed }
        XCTAssertTrue(unconfirmed)
        XCTAssertTrue(model.isMirroring)
        XCTAssertEqual(scrcpy.stopCalls, 1)

        model.connectAndMirror()
        await Task.yield()
        XCTAssertEqual(adb.connectCalls.count, 1)
        XCTAssertEqual(scrcpy.startCalls.count, 1)

        scrcpy.triggerExit(at: 0, status: 0)
        let recovered = await eventually { model.state == .connected && !model.isMirroring }
        XCTAssertTrue(recovered)
    }

    func testPairingCodeIsSentOnStdinAndNeverAppearsInProcessArgumentsOrResult() async throws {
        let pairingCode = "pairing-\(UUID().uuidString)"
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            printf 'ARGS:%s\\n' "$*"
            IFS= read -r pairing_code
            if [ -n "$pairing_code" ]; then
                printf 'STDIN_RECEIVED\\n'
            else
                printf 'STDIN_INVALID\\n'
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let adb = ADBService(executableURL: script, environment: ["PATH": "/usr/bin:/bin"])
        let result = await adb.pair(address: "127.0.0.1:37001", code: pairingCode)

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("ARGS:pair 127.0.0.1:37001"))
        XCTAssertTrue(result.stdout.contains("STDIN_RECEIVED"))
        XCTAssertFalse(result.stdout.contains(pairingCode))
        XCTAssertFalse(result.stderr.contains(pairingCode))
    }

    func testCommandRunnerTerminatesACommandAtItsDeadline() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            sleep 2
            printf 'completed\\n'
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let runner = CommandRunner(
            executableURL: script,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 0.05
        )
        let result = await runner.run([])

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("timed out"))
        XCTAssertFalse(result.stdout.contains("completed"))
    }

    func testCommandRunnerCancellationTerminatesTheChild() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            sleep 2
            printf 'completed\\n'
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let runner = CommandRunner(
            executableURL: script,
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5
        )
        let task = Task { await runner.run([]) }
        await Task.yield()
        task.cancel()
        let result = await task.value

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("cancelled"))
        XCTAssertFalse(result.stdout.contains("completed"))
    }

    func testScrcpyStartDoesNotImplicitlyStopAnUnconfirmedSession() async throws {
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            sleep 2
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let service = ScrcpyService(executableURL: script, environment: ["PATH": "/usr/bin:/bin"])
        let exited = expectation(description: "scrcpy session exits")
        try service.start(
            endpoint: "127.0.0.1:41231",
            onOutput: { _ in },
            onExit: { _ in exited.fulfill() }
        )

        XCTAssertTrue(service.isRunning)
        XCTAssertThrowsError(try service.start(
            endpoint: "127.0.0.1:41232",
            onOutput: { _ in },
            onExit: { _ in }
        )) { error in
            XCTAssertTrue(error is ScrcpyServiceError)
        }

        service.stop()
        await fulfillment(of: [exited], timeout: 2)
    }

    func testConnectFailureReleasesBusyStateAndCanRetry() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        adb.connectResult = CommandResult(exitCode: 1, stdout: "", stderr: "connection refused")
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let failed = await eventually { model.state == .error && !model.isBusy }
        XCTAssertTrue(failed)
        XCTAssertFalse(model.isMirroring)
        XCTAssertTrue(model.statusMessage.contains("连接失败"))

        adb.connectResult = CommandResult(exitCode: 0, stdout: "connected", stderr: "")
        model.connectAndMirror()
        let retried = await eventually { model.state == .mirroring }
        XCTAssertTrue(retried)
        XCTAssertEqual(adb.connectCalls.count, 2)
    }

    func testConnectOutputFailureIsRecoverableEvenWithZeroExitCode() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        adb.connectResult = CommandResult(
            exitCode: 0,
            stdout: "failed to connect to 192.168.1.7:41231",
            stderr: ""
        )
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()

        let failed = await eventually { model.state == .error && !model.isBusy }
        XCTAssertTrue(failed)
        XCTAssertTrue(scrcpy.startCalls.isEmpty)
    }

    func testScrcpyStartFailureReleasesSessionAndCanRetry() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        scrcpy.startError = TestError.scrcpyUnavailable
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let failed = await eventually { model.state == .error && !model.isBusy }
        XCTAssertTrue(failed)
        XCTAssertFalse(model.isMirroring)
        XCTAssertTrue(model.statusMessage.contains("scrcpy"))

        scrcpy.startError = nil
        model.connectAndMirror()
        let retried = await eventually { model.state == .mirroring }
        XCTAssertTrue(retried)
        XCTAssertEqual(scrcpy.startCalls.count, 1)
    }

    func testDuplicateConnectWhileBusyAndMirroringDoesNotCreateSessions() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        adb.waitForConnect = true
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        model.connectAndMirror()
        let oneConnection = await eventually { adb.connectCalls.count == 1 }
        XCTAssertTrue(oneConnection)
        XCTAssertTrue(model.isBusy)

        adb.finishPendingConnect(with: CommandResult(exitCode: 0, stdout: "connected", stderr: ""))
        let mirroring = await eventually { model.state == .mirroring }
        XCTAssertTrue(mirroring)
        model.connectAndMirror()
        await Task.yield()
        XCTAssertEqual(adb.connectCalls.count, 1)
        XCTAssertEqual(scrcpy.startCalls.count, 1)
    }

    func testStopDuringConnectInvalidatesLateResult() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        adb.waitForConnect = true
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let connecting = await eventually { model.isBusy }
        XCTAssertTrue(connecting)
        let started = await eventually { adb.connectCalls.count == 1 }
        XCTAssertTrue(started)
        model.stopMirror()
        XCTAssertTrue(model.isBusy)
        model.connectAndMirror()
        await Task.yield()
        XCTAssertEqual(adb.connectCalls.count, 1)
        adb.finishPendingConnect(with: CommandResult(exitCode: 0, stdout: "connected", stderr: ""))
        let cancelled = await eventually { !model.isBusy }
        XCTAssertTrue(cancelled)

        XCTAssertFalse(model.isMirroring)
        XCTAssertNotEqual(model.state, .mirroring)
        XCTAssertTrue(scrcpy.startCalls.isEmpty)
    }

    func testOldScrcpyExitCallbackCannotClearNewSession() async {
        let adb = FakeADB()
        let scrcpy = FakeScrcpy()
        configureDiscovery(adb)
        let model = AppModel(adb: adb, scrcpy: scrcpy, startsRefreshLoop: false)

        model.refreshNow()
        let discovered = await eventually { model.devices.count == 1 }
        XCTAssertTrue(discovered)
        model.connectAndMirror()
        let firstSession = await eventually { model.state == .mirroring }
        XCTAssertTrue(firstSession)
        model.stopMirror()
        XCTAssertTrue(model.isMirroring)
        XCTAssertEqual(model.state, .stopping)
        scrcpy.triggerExit(at: 0, status: 0)
        let firstExited = await eventually { model.state == .connected && !model.isMirroring }
        XCTAssertTrue(firstExited)

        model.connectAndMirror()
        let secondSession = await eventually {
            model.state == .mirroring && scrcpy.startCallDetails.count == 2
        }
        XCTAssertTrue(secondSession)

        scrcpy.triggerExit(at: 0, status: 9)
        await Task.yield()
        XCTAssertTrue(model.isMirroring)
        XCTAssertEqual(model.state, .mirroring)

        scrcpy.triggerExit(at: 1, status: 9)
        let exited = await eventually { !model.isMirroring && model.state == .connected }
        XCTAssertTrue(exited)
        XCTAssertTrue(model.statusMessage.contains("异常退出"))
    }

    private func configureDiscovery(_ adb: FakeADB) {
        adb.discoveryResult = DiscoveryResult(
            devices: [DiscoveredDevice(endpoint: "192.168.1.7:41231", serviceName: "pixel")],
            command: CommandResult(exitCode: 0, stdout: "", stderr: "")
        )
    }

    private func eventually(
        timeoutIterations: Int = 100,
        condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    private func makeExecutableScript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fixture.sh")
        try contents.data(using: .utf8)!.write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return script
    }
}
