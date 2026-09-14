import Foundation

/// Owns the `emulator` child process. Output goes to a log file under
/// `<root>/logs/`. Termination is observed through `terminated`.
public final class EmulatorProcess: @unchecked Sendable {
    public let options: EmulatorLaunchOptions
    public let logURL: URL
    private let process = Process()
    private let lock = NSLock()
    private var terminationContinuations: [CheckedContinuation<Int32, Never>] = []
    private var exitStatus: Int32?

    public init(paths: SDKPaths, options: EmulatorLaunchOptions) throws {
        self.options = options
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        logURL = paths.logs.appendingPathComponent("emulator-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        process.executableURL = paths.emulatorBinary
        process.arguments = options.arguments
        process.environment = options.gpuBackend.environment(from: paths.environment(adbServerPort: options.adbServerPort))
        process.currentDirectoryURL = paths.root
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            try? handle.close()
            self?.finish(status: p.terminationStatus)
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        Log.emulator.info("launching \(self.process.executableURL!.path) \(self.options.arguments.joined(separator: " "))")
        try process.run()
    }

    /// Resolves when the process exits.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let s = exitStatus { lock.unlock(); cont.resume(returning: s); return }
            terminationContinuations.append(cont)
            lock.unlock()
        }
    }

    private func finish(status: Int32) {
        lock.lock()
        exitStatus = status
        let conts = terminationContinuations
        terminationContinuations = []
        lock.unlock()
        Log.emulator.info("emulator exited with status \(status)")
        conts.forEach { $0.resume(returning: status) }
    }

    /// Waits for exit, giving up after `timeout`. Returns whether it exited.
    public func waitForExit(timeout: Duration) async -> Bool {
        // A task group must join every child; cancelling a continuation-based
        // wait does not wake it, so racing waitForExit() against sleep hangs.
        let deadline = ContinuousClock.now + timeout
        while isRunning {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: min(remaining, .milliseconds(20))) }
            catch { return false }
        }
        return true
    }

    public func terminate() { if process.isRunning { process.terminate() } }
    public func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    /// Last lines of the log for error reporting.
    public func tailLog(lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
