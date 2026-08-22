import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
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

struct ToolLocator {
    let adbURL: URL?
    let scrcpyURL: URL?
    let processEnvironment: [String: String]

    init(bundle: Bundle = .main) {
        let adbURL = Self.resolve(name: "adb", bundle: bundle)
        let scrcpyURL = Self.resolve(name: "scrcpy", bundle: bundle)
        self.adbURL = adbURL
        self.scrcpyURL = scrcpyURL

        var directories: [String] = []
        if let adbURL {
            directories.append(adbURL.deletingLastPathComponent().path)
        }
        if let scrcpyURL {
            directories.append(scrcpyURL.deletingLastPathComponent().path)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.unique(directories).joined(separator: ":")
        self.processEnvironment = environment
    }

    private static func resolve(name: String, bundle: Bundle) -> URL? {
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

        if let path = ProcessInfo.processInfo.environment["PATH"] {
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

final class CommandRunner: @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]

    init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.environment = environment
    }

    func run(_ arguments: [String]) async -> CommandResult {
        let executableURL = executableURL
        let environment = environment

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdout = String(
                        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    let stderr = String(
                        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""

                    continuation.resume(returning: CommandResult(
                        exitCode: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    ))
                } catch {
                    continuation.resume(returning: CommandResult(
                        exitCode: -1,
                        stdout: "",
                        stderr: error.localizedDescription
                    ))
                }
            }
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

final class ADBService: @unchecked Sendable {
    private let runner: CommandRunner

    init(executableURL: URL, environment: [String: String]) {
        self.runner = CommandRunner(executableURL: executableURL, environment: environment)
    }

    func startServer() async -> CommandResult {
        await runner.run(["start-server"])
    }

    func pair(address: String, code: String) async -> CommandResult {
        await runner.run(["pair", address, code])
    }

    func connect(endpoint: String) async -> CommandResult {
        await runner.run(["connect", endpoint])
    }

    func discover() async -> (devices: [DiscoveredDevice], result: CommandResult) {
        let result = await runner.run(["mdns", "services"])
        return (Self.parseMDNS(result.stdout), result)
    }

    static func parseMDNS(_ output: String) -> [DiscoveredDevice] {
        let serviceType = "_adb-tls-connect._tcp"
        var devices: [DiscoveredDevice] = []
        var seen = Set<String>()

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let serviceIndex = fields.firstIndex(where: { String($0) == serviceType }),
                  fields.count > serviceIndex + 1 else {
                continue
            }

            let endpoint = String(fields[serviceIndex + 1])
            guard !endpoint.isEmpty, seen.insert(endpoint).inserted else {
                continue
            }

            let serviceName = serviceIndex > 0 ? String(fields[serviceIndex - 1]) : endpoint
            devices.append(DiscoveredDevice(endpoint: endpoint, serviceName: serviceName))
        }

        return devices.sorted { $0.endpoint.localizedStandardCompare($1.endpoint) == .orderedAscending }
    }
}

final class ScrcpyService: @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?

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
        stop()

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

        try newProcess.run()

        lock.lock()
        process = newProcess
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let currentProcess = process
        lock.unlock()

        guard let currentProcess, currentProcess.isRunning else { return }
        currentProcess.terminate()
    }
}
