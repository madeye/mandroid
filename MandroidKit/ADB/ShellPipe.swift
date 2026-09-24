import Foundation

/// A long-running `adb shell` command fed line by line on stdin (e.g. the
/// `ScrollInjector` guest helper). Writes never block: a line the helper has
/// not caught up with is dropped, and a write after it exits fails instead
/// of raising SIGPIPE.
final class ShellPipe: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var outputText = ""
    private var stopped = false
    private var readyWaiter: CheckedContinuation<Void, Error>?

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let fd = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    var isRunning: Bool { process.isRunning }

    /// Launches the command and returns once its output contains `readyLine`.
    func start(readyLine: String, timeout: Duration) async throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            lock.withLock {
                // Keep only a tail for error messages.
                outputText = String((outputText + String(decoding: data, as: UTF8.self)).suffix(2000))
                if outputText.contains(readyLine) { resumeWaiter(nil) }
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            lock.withLock {
                let message = "guest helper exited (\(p.terminationStatus)): \(outputText)"
                if !stopped { Log.adb.error("\(message, privacy: .public)") }
                resumeWaiter(MandroidKitError.adb(message))
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { readyWaiter = cont }
            do { try process.run() } catch { lock.withLock { resumeWaiter(error) } }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                lock.withLock { resumeWaiter(MandroidKitError.timeout("guest helper start")) }
            }
        }
    }

    private func resumeWaiter(_ error: Error?) {
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    /// False once the helper has gone; true when the line was sent or dropped.
    func write(_ line: String) -> Bool {
        lock.withLock {
            guard !stopped, process.isRunning else { return false }
            let bytes = Array(line.utf8)
            // Writes up to PIPE_BUF are atomic, so a line is never split.
            let n = bytes.withUnsafeBufferPointer { Darwin.write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count) }
            return n >= 0 || errno == EAGAIN
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }
}
