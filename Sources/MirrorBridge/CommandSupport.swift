import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct CommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ScrcpyExitObservation: Sendable, Equatable {
    case exited
    case stillRunning
}

enum ToolLocatorError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "找不到工具：\(name)。请安装后重试，或将它放入 App Bundle 的 Resources/bin。"
        }
    }
}

enum ToolStatus: Equatable {
    case ready
    case missingADB
    case missingScrcpy
    case missingBoth

    init(adbAvailable: Bool, scrcpyAvailable: Bool) {
        switch (adbAvailable, scrcpyAvailable) {
        case (true, true): self = .ready
        case (false, true): self = .missingADB
        case (true, false): self = .missingScrcpy
        case (false, false): self = .missingBoth
        }
    }

    var message: String {
        switch self {
        case .ready:
            return "工具已就绪。"
        case .missingADB:
            return "未找到 adb。请安装 Android SDK Platform-Tools，然后点击刷新。"
        case .missingScrcpy:
            return "未找到 scrcpy。请安装 scrcpy，然后点击刷新。"
        case .missingBoth:
            return "未找到 adb 和 scrcpy。请安装这两个工具，然后点击刷新。"
        }
    }
}

struct ToolPaths: Equatable {
    let adbURL: URL?
    let scrcpyURL: URL?
    let processEnvironment: [String: String]
}

protocol ToolLocating {
    func locate() -> ToolPaths
}

struct ToolLocator: ToolLocating {
    private let bundle: Bundle
    private let environment: [String: String]?

    init(
        bundle: Bundle = .main,
        environment: [String: String]? = nil
    ) {
        self.bundle = bundle
        self.environment = environment
    }

    var adbURL: URL? { locate().adbURL }
    var scrcpyURL: URL? { locate().scrcpyURL }
    var processEnvironment: [String: String] { locate().processEnvironment }

    func locate() -> ToolPaths {
        let environment = environment ?? ProcessInfo.processInfo.environment
        let adbURL = Self.resolve(name: "adb", bundle: bundle, environment: environment)
        let scrcpyURL = Self.resolve(name: "scrcpy", bundle: bundle, environment: environment)

        var directories: [String] = []
        if let adbURL {
            directories.append(adbURL.deletingLastPathComponent().path)
        }
        if let scrcpyURL {
            directories.append(scrcpyURL.deletingLastPathComponent().path)
        }
        if let path = environment["PATH"] {
            directories.append(path)
        }

        var processEnvironment = environment
        processEnvironment["PATH"] = Self.unique(directories).joined(separator: ":")
        return ToolPaths(
            adbURL: adbURL,
            scrcpyURL: scrcpyURL,
            processEnvironment: processEnvironment
        )
    }

    private static func resolve(
        name: String,
        bundle: Bundle,
        environment: [String: String]
    ) -> URL? {
        if let bundled = bundle.url(forResource: name, withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            home.appendingPathComponent("Library/Android/sdk/platform-tools/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)")
        ]

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            })
        }

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private final class CommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private enum CommandTerminationReason {
    case timedOut
    case cancelled
}

private final class CommandExecution: @unchecked Sendable {
    private static let forcedTerminationDelay: TimeInterval = 0.25

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let standardInput: Data?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var terminationReason: CommandTerminationReason?
    private var timeoutWorkItem: DispatchWorkItem?
    private var continuation: CheckedContinuation<CommandResult, Never>?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
    }

    func run() async -> CommandResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let cancelled = cancellationRequested
            lock.unlock()

            if cancelled {
                finish(CommandResult(exitCode: -3, stdout: "", stderr: "command cancelled"))
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    execute()
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        if terminationReason == nil, let currentProcess = process, currentProcess.isRunning {
            terminationReason = .cancelled
        }
        let currentProcess = process
        lock.unlock()

        terminate(currentProcess)
    }

    private func execute() {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput.map { _ in Pipe() }
        let stdoutCollector = CommandOutputCollector()
        let stderrCollector = CommandOutputCollector()
        let outputGroup = DispatchGroup()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCollector.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCollector.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        lock.lock()
        let cancelledBeforeRun = cancellationRequested
        if !cancelledBeforeRun {
            self.process = process
        }
        lock.unlock()

        guard !cancelledBeforeRun else {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            outputGroup.wait()
            finish(CommandResult(exitCode: -3, stdout: "", stderr: "command cancelled"))
            return
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            outputGroup.wait()
            finish(CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
            return
        }

        if let standardInput, let stdinPipe {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: standardInput)
            } catch {
                requestTermination(.cancelled)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        lock.lock()
        let cancelledAfterRun = cancellationRequested
        lock.unlock()
        if cancelledAfterRun {
            requestTermination(.cancelled)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.requestTermination(.timedOut)
        }
        lock.lock()
        self.timeoutWorkItem = timeoutWorkItem
        let shouldScheduleTimeout = terminationReason == nil
        lock.unlock()
        if shouldScheduleTimeout {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
        }

        process.waitUntilExit()
        if outputGroup.wait(timeout: .now() + Self.forcedTerminationDelay) == .timedOut {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            outputGroup.wait()
        }

        let stdout = String(data: stdoutCollector.value(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrCollector.value(), encoding: .utf8) ?? ""
        lock.lock()
        let reason = terminationReason
        lock.unlock()

        switch reason {
        case .timedOut:
            finish(CommandResult(
                exitCode: -2,
                stdout: stdout,
                stderr: stderr.isEmpty
                    ? "command timed out after \(timeout) seconds"
                    : "command timed out after \(timeout) seconds\n" + stderr
            ))
        case .cancelled:
            finish(CommandResult(
                exitCode: -3,
                stdout: stdout,
                stderr: stderr.isEmpty ? "command cancelled" : "command cancelled\n" + stderr
            ))
        case nil:
            finish(CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr))
        }
    }

    private func requestTermination(_ reason: CommandTerminationReason) {
        lock.lock()
        guard let currentProcess = process, currentProcess.isRunning else {
            lock.unlock()
            return
        }
        if terminationReason == nil {
            terminationReason = reason
        }
        lock.unlock()

        terminate(currentProcess)
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.forcedTerminationDelay
        ) {
            guard process.isRunning else { return }
            #if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
            #endif
        }
    }

    private func finish(_ result: CommandResult) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        process = nil
        timeoutWorkItem?.cancel()
        lock.unlock()
        continuation.resume(returning: result)
    }
}

final class CommandRunner: @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let timeout: TimeInterval

    init(executableURL: URL, environment: [String: String], timeout: TimeInterval = 15) {
        self.executableURL = executableURL
        self.environment = environment
        self.timeout = timeout
    }

    func run(
        _ arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) async -> CommandResult {
        let execution = CommandExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout ?? self.timeout
        )
        return await withTaskCancellationHandler {
            await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let endpoint: String
    let serviceName: String

    var id: String { endpoint }

    var displayName: String {
        if serviceName.isEmpty || serviceName == endpoint {
            return endpoint
        }
        return "\(serviceName) · \(endpoint)"
    }
}

struct DiscoveryResult: Sendable {
    let devices: [DiscoveredDevice]
    let command: CommandResult
}

protocol ADBClient: AnyObject, Sendable {
    func startServer() async -> CommandResult
    func pair(address: String, code: String) async -> CommandResult
    func connect(endpoint: String) async -> CommandResult
    func discover() async -> DiscoveryResult
}

protocol BonjourClient: AnyObject, Sendable {
    func discover() async -> [DiscoveredDevice]
}

final class BonjourService: BonjourClient, @unchecked Sendable {
    private enum Timeout {
        static let browse: TimeInterval = 2
        static let resolution: TimeInterval = 2
    }

    private static let serviceType = "_adb-tls-connect._tcp"
    private let runner: CommandRunner?

    init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let executableURL = executableURL ?? Self.resolveExecutable(environment: environment)
        self.runner = executableURL.map {
            CommandRunner(executableURL: $0, environment: environment)
        }
    }

    func discover() async -> [DiscoveredDevice] {
        guard let runner else { return [] }

        // dns-sd streams browse and resolve events, so the bounded commands intentionally
        // return their partial stdout when the command deadline is reached.
        let browse = await runner.run(
            ["-B", Self.serviceType, "local"],
            timeout: Timeout.browse
        )
        let serviceNames = Self.parseBrowse(browse.stdout)
        guard !serviceNames.isEmpty else { return [] }

        return await withTaskGroup(of: DiscoveredDevice?.self, returning: [DiscoveredDevice].self) { group in
            for serviceName in serviceNames {
                group.addTask { [runner] in
                    let resolution = await runner.run(
                        ["-L", serviceName, Self.serviceType, "local"],
                        timeout: Timeout.resolution
                    )
                    guard let endpoint = Self.parseResolution(resolution.stdout) else {
                        return nil
                    }
                    return DiscoveredDevice(endpoint: endpoint, serviceName: serviceName)
                }
            }

            var devices: [DiscoveredDevice] = []
            for await device in group {
                if let device {
                    devices.append(device)
                }
            }

            var seen = Set<String>()
            return devices
                .filter { seen.insert($0.endpoint).inserted }
                .sorted {
                    $0.endpoint.localizedStandardCompare($1.endpoint) == .orderedAscending
                }
        }
    }

    static func parseBrowse(_ output: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.contains(where: { String($0) == "Add" }),
                  let serviceIndex = fields.firstIndex(where: {
                      Self.normalizedServiceType(String($0)) == serviceType
                  }),
                  fields.count > serviceIndex + 1 else {
                continue
            }

            let name = String(fields[serviceIndex + 1])
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }

        return names
    }

    static func parseResolution(_ output: String) -> String? {
        let marker = " can be reached at "
        for line in output.split(whereSeparator: \.isNewline) {
            guard let markerRange = line.range(of: marker) else { continue }
            let endpoint = line[markerRange.upperBound...]
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map(String.init) ?? ""
            if ADBService.isValidEndpoint(endpoint) {
                return endpoint
            }
        }
        return nil
    }

    private static func normalizedServiceType(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func resolveExecutable(environment: [String: String]) -> URL? {
        var candidates = [
            URL(fileURLWithPath: "/usr/bin/dns-sd"),
            URL(fileURLWithPath: "/usr/sbin/dns-sd")
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("dns-sd")
            })
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}

final class ADBService: ADBClient, @unchecked Sendable {
    private enum Timeout {
        static let startServer: TimeInterval = 5
        static let discovery: TimeInterval = 5
        static let pairing: TimeInterval = 30
        static let connection: TimeInterval = 15
    }

    private let runner: CommandRunner
    private let bonjour: any BonjourClient

    init(
        executableURL: URL,
        environment: [String: String],
        bonjour: (any BonjourClient)? = nil
    ) {
        self.runner = CommandRunner(executableURL: executableURL, environment: environment)
        self.bonjour = bonjour ?? BonjourService(environment: environment)
    }

    func startServer() async -> CommandResult {
        await runner.run(["start-server"], timeout: Timeout.startServer)
    }

    func pair(address: String, code: String) async -> CommandResult {
        let input = Data((code + "\n").utf8)
        let result = await runner.run(
            ["pair", address],
            standardInput: input,
            timeout: Timeout.pairing
        )
        return CommandResult(
            exitCode: result.exitCode,
            stdout: Self.redact(result.stdout, value: code),
            stderr: Self.redact(result.stderr, value: code)
        )
    }

    func connect(endpoint: String) async -> CommandResult {
        await runner.run(["connect", endpoint], timeout: Timeout.connection)
    }

    func discover() async -> DiscoveryResult {
        let command = await runner.run(["mdns", "services"], timeout: Timeout.discovery)
        let devices = Self.parseMDNS(command.stdout)
        guard devices.isEmpty, command.succeeded else {
            return DiscoveryResult(devices: devices, command: command)
        }
        return DiscoveryResult(devices: await bonjour.discover(), command: command)
    }

    static func parseMDNS(_ output: String) -> [DiscoveredDevice] {
        let serviceType = "_adb-tls-connect._tcp"
        var devices: [DiscoveredDevice] = []
        var seen = Set<String>()

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let serviceIndex = fields.firstIndex(where: {
                let value = String($0)
                return value == serviceType || value == "\(serviceType)."
            }),
                  fields.count > serviceIndex + 1 else {
                continue
            }

            let endpoint = String(fields[serviceIndex + 1])
            guard Self.isValidEndpoint(endpoint), seen.insert(endpoint).inserted else {
                continue
            }

            let serviceName = serviceIndex > 0 ? String(fields[serviceIndex - 1]) : endpoint
            devices.append(DiscoveredDevice(endpoint: endpoint, serviceName: serviceName))
        }

        return devices.sorted {
            $0.endpoint.localizedStandardCompare($1.endpoint) == .orderedAscending
        }
    }

    private static func redact(_ message: String, value: String) -> String {
        guard !value.isEmpty else { return message }
        return message.replacingOccurrences(of: value, with: "<redacted>")
    }

    fileprivate static func isValidEndpoint(_ endpoint: String) -> Bool {
        guard !endpoint.isEmpty, !endpoint.contains(where: \.isWhitespace) else {
            return false
        }

        let host: Substring
        let port: Substring
        if endpoint.first == "[" {
            guard let closingBracket = endpoint.firstIndex(of: "]"),
                  endpoint.index(after: closingBracket) < endpoint.endIndex,
                  endpoint[endpoint.index(after: closingBracket)] == ":" else {
                return false
            }
            host = endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket]
            port = endpoint[endpoint.index(closingBracket, offsetBy: 2)...]
        } else {
            guard let separator = endpoint.lastIndex(of: ":") else {
                return false
            }
            host = endpoint[..<separator]
            port = endpoint[endpoint.index(after: separator)...]
        }

        guard !host.isEmpty, let portNumber = UInt16(port) else {
            return false
        }
        return portNumber > 0
    }
}

protocol ScrcpyClient: AnyObject, Sendable {
    var isRunning: Bool { get }

    func start(
        endpoint: String,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws

    func stop()
    func observeExit() async -> ScrcpyExitObservation
}

enum ScrcpyServiceError: LocalizedError {
    case sessionAlreadyActive

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "已有 scrcpy 会话正在退出确认中。"
        }
    }
}

final class ScrcpyService: ScrcpyClient, @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var terminationRequested = false

    init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.environment = environment
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    func start(
        endpoint: String,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        lock.lock()
        let hasActiveProcess = process != nil
        lock.unlock()
        if hasActiveProcess {
            throw ScrcpyServiceError.sessionAlreadyActive
        }

        let newProcess = Process()
        let outputPipe = Pipe()
        newProcess.executableURL = executableURL
        newProcess.arguments = [
            "-s", endpoint,
            "--window-title", "MirrorBridge · \(endpoint)"
        ]
        newProcess.environment = environment
        newProcess.currentDirectoryURL = executableURL.deletingLastPathComponent()
        newProcess.standardInput = FileHandle.nullDevice
        newProcess.standardOutput = outputPipe
        newProcess.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                onOutput(text)
            }
        }

        newProcess.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            self?.lock.lock()
            if self?.process === process {
                self?.process = nil
            }
            self?.lock.unlock()
            onExit(process.terminationStatus)
        }

        lock.lock()
        guard process == nil else {
            lock.unlock()
            throw ScrcpyServiceError.sessionAlreadyActive
        }
        process = newProcess
        terminationRequested = false
        lock.unlock()

        do {
            try newProcess.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            if process === newProcess {
                process = nil
                terminationRequested = false
            }
            lock.unlock()
            throw error
        }
    }

    func stop() {
        lock.lock()
        let currentProcess = process
        guard !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        lock.unlock()

        guard let currentProcess, currentProcess.isRunning else { return }
        currentProcess.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            guard currentProcess.isRunning else { return }
            #if canImport(Darwin)
            kill(currentProcess.processIdentifier, SIGKILL)
            #endif
        }
    }

    func observeExit() async -> ScrcpyExitObservation {
        processHasExited() ? .exited : .stillRunning
    }

    private func processHasExited() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return process == nil
    }
}
