import Foundation
import SwiftUI

typealias ADBClientFactory = (URL, [String: String]) -> any ADBClient
typealias ScrcpyClientFactory = (URL, [String: String]) -> any ScrcpyClient

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case checking
        case waiting
        case discovered
        case pairing
        case connecting
        case connected
        case mirroring
        case stopping
        case stopUnconfirmed
        case error

        var title: String {
            switch self {
            case .checking: return "检查环境"
            case .waiting: return "等待无线调试"
            case .discovered: return "发现设备"
            case .pairing: return "正在配对"
            case .connecting: return "正在连接"
            case .connected: return "已连接"
            case .mirroring: return "镜像中"
            case .stopping: return "正在停止"
            case .stopUnconfirmed: return "停止未确认"
            case .error: return "需要处理"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .checking
    @Published private(set) var statusMessage = "正在检查 adb 和 scrcpy…"
    @Published private(set) var toolStatus: ToolStatus = .missingBoth
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var selectedEndpoint: String?
    @Published var pairingAddress = ""
    @Published var pairingCode = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isMirroring = false
    @Published private(set) var logText = ""
    @Published private(set) var adbPath: String?
    @Published private(set) var scrcpyPath: String?

    private var adb: (any ADBClient)?
    private var scrcpy: (any ScrcpyClient)?
    private let toolLocator: (any ToolLocating)?
    private let adbFactory: ADBClientFactory
    private let scrcpyFactory: ScrcpyClientFactory
    private let stopConfirmationTimeout: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var stopConfirmationTask: Task<Void, Never>?
    private var activeOperationTask: Task<Void, Never>?
    private var activeOperationID: UInt64?
    private var cancelledOperationID: UInt64?
    private var operationID: UInt64 = 0
    private var activeMirrorSession: UInt64?
    private var mirrorStopRequestedSession: UInt64?
    private var latestRefreshID: UInt64 = 0
    private var adbServerReady = false
    private var refreshInFlight = false

    init(
        toolLocator: any ToolLocating = ToolLocator(),
        adbFactory: @escaping ADBClientFactory = { executableURL, environment in
            ADBService(executableURL: executableURL, environment: environment)
        },
        scrcpyFactory: @escaping ScrcpyClientFactory = { executableURL, environment in
            ScrcpyService(executableURL: executableURL, environment: environment)
        },
        startsRefreshLoop: Bool = true,
        stopConfirmationTimeout: TimeInterval = 4
    ) {
        let paths = toolLocator.locate()
        self.toolLocator = toolLocator
        self.adbFactory = adbFactory
        self.scrcpyFactory = scrcpyFactory
        self.stopConfirmationTimeout = stopConfirmationTimeout
        self.adbPath = paths.adbURL?.path
        self.scrcpyPath = paths.scrcpyURL?.path
        self.toolStatus = ToolStatus(
            adbAvailable: paths.adbURL != nil,
            scrcpyAvailable: paths.scrcpyURL != nil
        )
        self.adb = paths.adbURL.map { adbFactory($0, paths.processEnvironment) }
        self.scrcpy = paths.scrcpyURL.map { scrcpyFactory($0, paths.processEnvironment) }

        if toolStatus != .ready {
            self.state = .error
            self.statusMessage = toolStatus.message
        }

        if startsRefreshLoop {
            refreshTask = Task { [weak self] in
                await self?.refreshLoop()
            }
        }
    }

    init(
        adb: (any ADBClient)?,
        scrcpy: (any ScrcpyClient)?,
        adbPath: String? = nil,
        scrcpyPath: String? = nil,
        startsRefreshLoop: Bool = false,
        stopConfirmationTimeout: TimeInterval = 4
    ) {
        self.toolLocator = nil
        self.adbFactory = { _, _ in
            fatalError("Injected AppModel does not create ADB clients")
        }
        self.scrcpyFactory = { _, _ in
            fatalError("Injected AppModel does not create scrcpy clients")
        }
        self.stopConfirmationTimeout = stopConfirmationTimeout
        self.adb = adb
        self.scrcpy = scrcpy
        self.adbPath = adbPath ?? (adb == nil ? nil : "injected adb")
        self.scrcpyPath = scrcpyPath ?? (scrcpy == nil ? nil : "injected scrcpy")
        self.toolStatus = ToolStatus(adbAvailable: adb != nil, scrcpyAvailable: scrcpy != nil)

        if toolStatus != .ready {
            self.state = .error
            self.statusMessage = toolStatus.message
        }

        if startsRefreshLoop {
            refreshTask = Task { [weak self] in
                await self?.refreshLoop()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        stopConfirmationTask?.cancel()
        activeOperationTask?.cancel()
        if activeMirrorSession != nil, mirrorStopRequestedSession == nil {
            scrcpy?.stop()
        }
    }

    var canPair: Bool {
        !pairingAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isBusy && !isMirroring && adbServerReady && adb != nil
    }

    var canMirror: Bool {
        selectedEndpoint != nil &&
        !isBusy &&
        !isMirroring &&
        adbServerReady &&
        adb != nil &&
        scrcpy != nil
    }

    func refreshNow() {
        guard !isBusy, !refreshInFlight else { return }
        let recheckEnvironment = !isMirroring
        refreshInFlight = true
        activeOperationTask = Task { [weak self] in
            _ = await self?.refreshDevices(recheckEnvironment: recheckEnvironment)
        }
    }

    func pair() {
        let address = pairingAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              !code.isEmpty,
              !isBusy,
              !isMirroring,
              adbServerReady,
              let adb else { return }

        pairingCode = ""
        let operation = beginOperation()
        activeOperationID = operation
        isBusy = true
        state = .pairing
        statusMessage = "正在使用 \(address) 配对…"
        appendLog("adb pair \(address)")

        activeOperationTask = Task { [weak self, adb] in
            let result = await adb.pair(address: address, code: code)
            guard let self else { return }
            guard self.isCurrentOperation(operation) else {
                self.resolveCancelledOperation(operation)
                return
            }

            self.appendResult(result, redactedValues: [code])
            self.isBusy = false
            if result.succeeded {
                self.state = .waiting
                self.statusMessage = "配对成功。请保持无线调试开启，等待发现连接服务。"
            } else {
                self.state = .error
                self.statusMessage = "配对失败，请检查地址、配对码和局域网连接后重试。"
            }
            _ = await self.refreshDevices(recheckEnvironment: false)
            self.finishOperation(operation)
        }
    }

    func connectAndMirror() {
        guard canMirror, let endpoint = selectedEndpoint, let adb, let scrcpy else { return }

        let operation = beginOperation()
        activeOperationID = operation
        isBusy = true
        state = .connecting
        statusMessage = "正在连接 \(endpoint)…"
        appendLog("adb connect \(endpoint)")

        activeOperationTask = Task { [weak self, adb, scrcpy] in
            let result = await adb.connect(endpoint: endpoint)
            guard let self else { return }
            guard self.isCurrentOperation(operation) else {
                self.resolveCancelledOperation(operation)
                return
            }

            self.appendResult(result)
            guard Self.connectionSucceeded(result) else {
                self.isBusy = false
                self.activeMirrorSession = nil
                self.finishOperation(operation)
                self.state = .error
                self.statusMessage = "连接失败。请确认手机已打开 Wireless debugging，然后重试。"
                return
            }

            do {
                self.activeMirrorSession = operation
                self.isMirroring = true
                try scrcpy.start(
                    endpoint: endpoint,
                    onOutput: { [weak self] text in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.activeMirrorSession == operation else { return }
                            self.appendLog(text)
                        }
                    },
                    onExit: { [weak self] status in
                        Task { @MainActor [weak self] in
                            self?.handleMirrorExit(session: operation, status: status)
                        }
                    }
                )
            } catch {
                scrcpy.stop()
                self.isBusy = false
                self.activeMirrorSession = nil
                self.isMirroring = false
                self.finishOperation(operation)
                self.state = .error
                self.statusMessage = "无法启动 scrcpy，请检查安装和设备连接后重试。"
                self.appendLog("scrcpy 启动失败：\(error.localizedDescription)")
                return
            }

            guard self.isCurrentOperation(operation) else {
                scrcpy.stop()
                return
            }

            guard self.activeMirrorSession == operation else {
                return
            }

            self.finishOperation(operation)
            self.isBusy = false
            self.state = .mirroring
            self.statusMessage = "已连接，镜像窗口正在运行。"
        }
    }

    func stopMirror() {
        if let session = activeMirrorSession {
            guard mirrorStopRequestedSession != session else { return }

            _ = beginOperation()
            mirrorStopRequestedSession = session
            isBusy = true
            state = .stopping
            statusMessage = "正在等待镜像窗口退出确认…"
            scrcpy?.stop()
            scheduleStopConfirmation(for: session)
            return
        }

        guard isBusy, let operation = activeOperationID else { return }

        cancelledOperationID = operation
        activeOperationTask?.cancel()
        _ = beginOperation()
        state = .connecting
        statusMessage = "正在取消当前 ADB 操作，等待退出确认…"
    }

    func clearLogs() {
        logText = ""
    }

    private func refreshLoop() async {
        guard adb != nil else {
            state = .error
            statusMessage = toolStatus.message
            return
        }

        while !Task.isCancelled {
            let refreshed = await refreshDevices(recheckEnvironment: false)
            guard refreshed else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func refreshDevices(recheckEnvironment: Bool) async -> Bool {
        refreshInFlight = true
        defer { refreshInFlight = false }

        let refreshID = beginRefresh()
        if recheckEnvironment && !isMirroring {
            refreshEnvironment()
        }

        guard toolStatus == .ready, let adb else {
            isBusy = false
            return false
        }

        let operation = beginOperation()
        activeOperationID = operation
        defer {
            if cancelledOperationID == operation {
                resolveCancelledOperation(operation)
            } else if activeOperationID == operation {
                activeOperationID = nil
                activeOperationTask = nil
            }
        }
        isBusy = true
        if !isMirroring {
            state = .checking
            statusMessage = "正在检查 ADB server…"
        }

        if !adbServerReady {
            let serverResult = await adb.startServer()
            guard refreshID == latestRefreshID, isCurrentOperation(operation) else {
                return false
            }
            guard serverResult.succeeded else {
                adbServerReady = false
                isBusy = false
                state = .error
                statusMessage = "ADB server 未启动，已阻断发现和连接；请刷新重试。"
                appendResult(serverResult)
                return false
            }
            adbServerReady = true
        }

        let discovery = await adb.discover()
        guard refreshID == latestRefreshID, isCurrentOperation(operation) else { return false }
        isBusy = false

        guard discovery.command.succeeded else {
            if !isMirroring {
                state = .error
            }
            let failure = discovery.command.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = failure.isEmpty
                ? "无法发现无线调试服务，请点击刷新重试。"
                : "无法发现无线调试服务：\(failure)"
            return true
        }

        devices = discovery.devices
        if let selectedEndpoint,
           !devices.contains(where: { $0.endpoint == selectedEndpoint }) {
            self.selectedEndpoint = nil
        }
        if self.selectedEndpoint == nil {
            self.selectedEndpoint = devices.first?.endpoint
        }

        guard !isMirroring else { return true }

        if !devices.isEmpty {
            state = .discovered
            statusMessage = "发现 \(devices.count) 台已配对的无线调试设备。"
        } else {
            state = .waiting
            statusMessage = "等待手机打开 Wireless debugging…"
        }
        return true
    }

    private func refreshEnvironment() {
        guard let toolLocator else { return }
        let paths = toolLocator.locate()
        adbPath = paths.adbURL?.path
        scrcpyPath = paths.scrcpyURL?.path
        toolStatus = ToolStatus(
            adbAvailable: paths.adbURL != nil,
            scrcpyAvailable: paths.scrcpyURL != nil
        )
        adbServerReady = false
        adb = paths.adbURL.map { adbFactory($0, paths.processEnvironment) }
        scrcpy = paths.scrcpyURL.map { scrcpyFactory($0, paths.processEnvironment) }

        if toolStatus != .ready {
            state = .error
            statusMessage = toolStatus.message
        }
    }

    private func appendResult(
        _ result: CommandResult,
        includeOutput: Bool = true,
        redactedValues: [String] = []
    ) {
        if includeOutput, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(redact(result.stdout, values: redactedValues))
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(redact(result.stderr, values: redactedValues))
        }
    }

    private func appendLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logText += "\n\(trimmed)"
        if logText.count > 12_000 {
            logText = String(logText.suffix(12_000))
        }
    }

    private func redact(_ message: String, values: [String]) -> String {
        values.reduce(message) { current, value in
            guard !value.isEmpty else { return current }
            return current.replacingOccurrences(of: value, with: "<redacted>")
        }
    }

    private func beginOperation() -> UInt64 {
        operationID &+= 1
        return operationID
    }

    private func isCurrentOperation(_ operation: UInt64) -> Bool {
        operationID == operation
    }

    private func beginRefresh() -> UInt64 {
        latestRefreshID &+= 1
        return latestRefreshID
    }

    private func finishOperation(_ operation: UInt64) {
        guard activeOperationID == operation else { return }
        activeOperationID = nil
        activeOperationTask = nil
        if cancelledOperationID == operation {
            cancelledOperationID = nil
        }
    }

    private func resolveCancelledOperation(_ operation: UInt64) {
        guard cancelledOperationID == operation else { return }

        finishOperation(operation)
        cancelledOperationID = nil
        isBusy = false
        state = devices.isEmpty ? .waiting : .connected
        statusMessage = "连接已取消，可再次重试。"
    }

    private func scheduleStopConfirmation(for session: UInt64) {
        stopConfirmationTask?.cancel()
        let timeout = max(0, stopConfirmationTimeout)
        let nanoseconds = UInt64(timeout * 1_000_000_000)
        stopConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.handleStopConfirmationTimeout(session: session)
        }
    }

    private func handleStopConfirmationTimeout(session: UInt64) {
        guard activeMirrorSession == session,
              mirrorStopRequestedSession == session else { return }

        state = .stopUnconfirmed
        statusMessage = "镜像窗口退出尚未确认，已阻断新的镜像会话。"
    }

    private func handleMirrorExit(session: UInt64, status: Int32) {
        guard activeMirrorSession == session else { return }

        let wasStopping = mirrorStopRequestedSession == session
        stopConfirmationTask?.cancel()
        stopConfirmationTask = nil
        activeMirrorSession = nil
        mirrorStopRequestedSession = nil
        isMirroring = false
        isBusy = false
        state = devices.isEmpty ? .waiting : .connected
        if wasStopping {
            statusMessage = "镜像已停止，ADB 连接仍保持，可再次连接。"
        } else if status == 0 {
            statusMessage = "镜像窗口已退出，可再次连接。"
        } else {
            statusMessage = "镜像窗口异常退出（状态码 \(status)），可再次重试。"
        }
        appendLog("scrcpy 退出，状态码：\(status)")
    }

    private static func connectionSucceeded(_ result: CommandResult) -> Bool {
        guard result.succeeded else { return false }
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        let failureMarkers = [
            "failed to connect",
            "unable to connect",
            "cannot connect",
            "connection refused",
            "no route to host",
            "offline"
        ]
        return !failureMarkers.contains(where: output.contains)
    }
}
