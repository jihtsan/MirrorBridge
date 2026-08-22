import Foundation
import SwiftUI

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
            case .error: return "需要处理"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .checking
    @Published private(set) var statusMessage = "正在检查 adb 和 scrcpy…"
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var selectedEndpoint: String?
    @Published var pairingAddress = ""
    @Published var pairingCode = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isMirroring = false
    @Published private(set) var logText = ""

    let adbPath: String?
    let scrcpyPath: String?

    private let adb: ADBService?
    private let scrcpy: ScrcpyService?
    private var refreshTask: Task<Void, Never>?

    init() {
        let locator = ToolLocator()
        self.adbPath = locator.adbURL?.path
        self.scrcpyPath = locator.scrcpyURL?.path

        if let adbURL = locator.adbURL {
            self.adb = ADBService(executableURL: adbURL, environment: locator.processEnvironment)
        } else {
            self.adb = nil
        }

        if let scrcpyURL = locator.scrcpyURL {
            self.scrcpy = ScrcpyService(executableURL: scrcpyURL, environment: locator.processEnvironment)
        } else {
            self.scrcpy = nil
        }

        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    deinit {
        refreshTask?.cancel()
        scrcpy?.stop()
    }

    var canPair: Bool {
        !pairingAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isBusy && adb != nil
    }

    var canMirror: Bool {
        selectedEndpoint != nil && !isBusy && scrcpy != nil && adb != nil
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refreshDevices()
        }
    }

    func pair() {
        let address = pairingAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !code.isEmpty, let adb else { return }

        Task { [weak self] in
            guard let self else { return }
            isBusy = true
            state = .pairing
            statusMessage = "正在使用 \(address) 配对…"
            appendLog("adb pair \(address)")

            let result = await adb.pair(address: address, code: code)
            appendResult(result)

            if result.succeeded {
                state = .waiting
                statusMessage = "配对成功。请保持无线调试开启，等待发现连接服务。"
            } else {
                state = .error
                statusMessage = "配对失败，请检查地址、配对码和局域网连接。"
            }
            isBusy = false
            await refreshDevices()
        }
    }

    func connectAndMirror() {
        guard let endpoint = selectedEndpoint, let adb, let scrcpy else { return }

        Task { [weak self] in
            guard let self else { return }
            isBusy = true
            state = .connecting
            statusMessage = "正在连接 \(endpoint)…"
            appendLog("adb connect \(endpoint)")

            let result = await adb.connect(endpoint: endpoint)
            appendResult(result)

            guard result.succeeded else {
                state = .error
                statusMessage = "连接失败。请确认手机已打开 Wireless debugging。"
                isBusy = false
                return
            }

            do {
                try scrcpy.start(
                    endpoint: endpoint,
                    onOutput: { [weak self] text in
                        Task { @MainActor [weak self] in
                            self?.appendLog(text)
                        }
                    },
                    onExit: { [weak self] status in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            isMirroring = false
                            if state == .mirroring {
                                state = .connected
                                statusMessage = "镜像窗口已退出（状态码 \(status)）。"
                            }
                            appendLog("scrcpy 退出，状态码：\(status)")
                        }
                    }
                )
                isMirroring = true
                state = .mirroring
                statusMessage = "已连接，镜像窗口正在运行。"
            } catch {
                state = .error
                statusMessage = "无法启动 scrcpy：\(error.localizedDescription)"
                appendLog(error.localizedDescription)
            }
            isBusy = false
        }
    }

    func stopMirror() {
        scrcpy?.stop()
        isMirroring = false
        if !devices.isEmpty {
            state = .connected
            statusMessage = "镜像已停止，ADB 连接仍保持。"
        } else {
            state = .waiting
            statusMessage = "镜像已停止。"
        }
    }

    func clearLogs() {
        logText = ""
    }

    private func refreshLoop() async {
        guard adb != nil else {
            state = .error
            statusMessage = "未找到 adb。请安装 Android SDK Platform-Tools。"
            return
        }

        let serverResult = await adb?.startServer()
        if let serverResult {
            appendResult(serverResult, includeOutput: false)
        }

        while !Task.isCancelled {
            await refreshDevices()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func refreshDevices() async {
        guard let adb else { return }

        let discovered = await adb.discover()
        let newDevices = discovered.devices
        devices = newDevices

        if let selectedEndpoint,
           !newDevices.contains(where: { $0.endpoint == selectedEndpoint }) {
            self.selectedEndpoint = nil
        }
        if self.selectedEndpoint == nil {
            self.selectedEndpoint = newDevices.first?.endpoint
        }

        if isMirroring {
            return
        }

        if !newDevices.isEmpty {
            state = .discovered
            statusMessage = "发现 \(newDevices.count) 台已配对的无线调试设备。"
        } else if discovered.result.succeeded {
            state = .waiting
            statusMessage = "等待手机打开 Wireless debugging…"
        } else {
            state = .error
            statusMessage = discovered.result.stderr.isEmpty
                ? "ADB 无法发现无线调试服务。"
                : discovered.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func appendResult(_ result: CommandResult, includeOutput: Bool = true) {
        if includeOutput, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(result.stdout)
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog(result.stderr)
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
}
