import Foundation

/// Thin async wrapper over the `adb` binary bound to one server port and one
/// device serial. All calls run through `Subprocess`.
public actor ADBClient {
    public let binary: URL
    public let serverPort: Int
    public let serial: String
    private let environment: [String: String]
    private var displayHelperDeployed = false
    private var proxyAgentDeployed = false

    public init(paths: SDKPaths, serverPort: Int, serial: String) {
        self.binary = paths.adbBinary
        self.serverPort = serverPort
        self.serial = serial
        self.environment = paths.environment(adbServerPort: serverPort)
    }

    /// Runs `adb -P <port> -s <serial> <args>` and returns stdout. Throws on a
    /// non-zero exit with stderr in the message.
    @discardableResult
    public func run(_ args: [String], timeout: Duration = .seconds(30)) async throws -> String {
        let all = ["-P", String(serverPort), "-s", serial] + args
        let r = try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
            group.addTask { try await Subprocess.run(self.binary, arguments: all, environment: self.environment) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MandroidKitError.timeout("adb \(args.joined(separator: " "))")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        guard r.status == 0 else {
            throw MandroidKitError.adb("\(args.first ?? "") failed (\(r.status)): \(r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))\(r.stdoutText.isEmpty ? "" : " " + r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.stdoutText
    }

    @discardableResult
    public func shell(_ command: String, timeout: Duration = .seconds(30)) async throws -> String {
        try await run(["shell", command], timeout: timeout)
    }

    /// Server-level command without `-s` (e.g. `kill-server`, `devices`).
    public func server(_ args: [String]) async throws -> String {
        let r = try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
            group.addTask { try await Subprocess.run(self.binary, arguments: ["-P", String(self.serverPort)] + args, environment: self.environment) }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw MandroidKitError.timeout("adb server command") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard r.status == 0 else { throw MandroidKitError.adb(r.stderrText) }
        return r.stdoutText
    }

    /// Starts the adb server on our port and waits for it. Done before the
    /// emulator launches: the emulator's own adb calls have short timeouts
    /// and, if no server is listening yet, every one of them forks another
    /// server that then fights for the port.
    public func startServer(timeout: Duration = .seconds(90)) async throws {
        let r = try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
            group.addTask { try await Subprocess.run(self.binary, arguments: ["-P", String(self.serverPort), "start-server"], environment: self.environment) }
            group.addTask { try await Task.sleep(for: timeout); throw MandroidKitError.timeout("adb start-server") }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        guard r.status == 0 else { throw MandroidKitError.adb("start-server failed: \(r.stderrText)") }
    }

    public func killServer() async {
        _ = try? await server(["kill-server"])
    }

    // MARK: Convenience

    /// adb shell takes a command string; Process argument boundaries do not
    /// survive the remote shell. Quote every interpolated string argument.
    public nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public func getprop(_ name: String) async throws -> String {
        try await shell("getprop \(Self.shellQuote(name))").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isBootCompleted() async -> Bool {
        (try? await getprop("sys.boot_completed")) == "1"
    }

    public func dumpsysDisplay() async throws -> String { try await shell("dumpsys display") }

    public func listThirdPartyPackages() async throws -> [String] {
        PackageListParser.parse(try await shell("pm list packages -3"))
    }

    /// `com.example/.MainActivity` for the launcher activity of `package`.
    public func launcherComponent(of package: String) async throws -> String? {
        let out = try await shell("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \(Self.shellQuote(package))")
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.contains("/") && !$0.hasPrefix("priority") }
    }

    public func startActivity(component: String, displayID: Int) async throws {
        let out = try await shell("am start --display \(displayID) -n \(Self.shellQuote(component))")
        if out.contains("Error") { throw MandroidKitError.adb(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Bind keyboard input to this display before an app creates its editor.
    /// With the default fallback-to-display-0 policy, Gboard can consume
    /// hardware keys without delivering them to secondary-display editors.
    public func configureDisplayIME(_ displayID: Int) async throws {
        guard displayID > 0 else { return }
        try await deployGuestHelper()
        let guestPath = "/data/local/tmp/mandroid-display-ime.jar"
        let output = try await shell("CLASSPATH=\(guestPath) app_process / DisplayIME \(displayID)")
        guard output.contains("local-ime-ready") else {
            throw MandroidKitError.adb("display IME setup failed: \(output)")
        }
    }

    /// Render the launcher's resolved Drawable in Android, where adaptive icons,
    /// vector resources and split APKs can be interpreted correctly.
    public func launcherIcon(of package: String) async throws -> Data {
        try await deployGuestHelper()
        let output = try await shell("CLASSPATH=/data/local/tmp/mandroid-display-ime.jar app_process / RenderAppIcon \(Self.shellQuote(package))")
        guard let png = Data(base64Encoded: output.trimmingCharacters(in: .whitespacesAndNewlines)),
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw MandroidKitError.adb("invalid launcher icon for \(package)")
        }
        return png
    }

    /// Starts the `ScrollInjector` helper; each line written to it becomes
    /// an Android mouse ACTION_SCROLL (see `ScrollChannel`).
    func startScrollInjector() async throws -> ShellPipe {
        try await deployGuestHelper()
        let pipe = ShellPipe(executable: binary, arguments: [
            "-P", String(serverPort), "-s", serial, "shell", "-T",
            "CLASSPATH=/data/local/tmp/mandroid-display-ime.jar app_process / ScrollInjector",
        ], environment: environment)
        do {
            try await pipe.start(readyLine: "scroll-ready", timeout: .seconds(15))
        } catch {
            pipe.stop()
            throw error
        }
        return pipe
    }

    private func deployGuestHelper() async throws {
        let guestPath = "/data/local/tmp/mandroid-display-ime.jar"
        if !displayHelperDeployed {
            guard let helper = Bundle(for: ADBClient.self).url(forResource: "guest-display", withExtension: "jar") else {
                throw MandroidKitError.adb("bundled display IME helper is missing")
            }
            _ = try await run(["push", helper.path, guestPath])
            displayHelperDeployed = true
        }
    }

    func deployProxyAgent() async throws {
        guard !proxyAgentDeployed else { return }
        guard let apk = Bundle(for: ADBClient.self).url(forResource: "proxy-agent", withExtension: "apk") else {
            throw MandroidKitError.adb("Bundled Android proxy helper is missing")
        }
        try await run(["install", "-r", apk.path], timeout: .seconds(120))
        proxyAgentDeployed = true
    }

    /// Let the desktop window's natural orientation drive activity layout.
    /// Ignoring display rotation alone still letterboxes portrait activities.
    /// These Android compatibility overrides also relax the activity bounds.
    /// --no-kill preserves a running task when a parked window resumes.
    public func useWindowOrientation(for package: String) async throws {
        let quotedPackage = Self.shellQuote(package)
        for change in ["OVERRIDE_ANY_ORIENTATION", "OVERRIDE_UNDEFINED_ORIENTATION_TO_NOSENSOR"] {
            let result = try await shell("am compat enable --no-kill \(change) \(quotedPackage)")
            guard result.contains("Enabled change") else {
                throw MandroidKitError.adb("orientation override unavailable: \(result)")
            }
        }
    }

    public func mediaVolume() async throws -> MediaVolume {
        let output = try await shell("cmd media_session volume --stream 3 --get")
        guard let volume = MediaVolume.parse(output) else {
            throw MandroidKitError.adb("Could not read Android media volume: \(output)")
        }
        return volume
    }

    public func setMediaVolume(percent: Int) async throws -> MediaVolume {
        let current = try await mediaVolume()
        let level = current.level(forPercent: percent)
        try await deployGuestHelper()
        let output = try await shell("CLASSPATH=/data/local/tmp/mandroid-display-ime.jar app_process / SetMediaVolume \(level)")
        guard output.contains("media-volume-ready") else {
            throw MandroidKitError.adb("Could not set Android media volume: \(output)")
        }
        let updated = try await mediaVolume()
        guard updated.level == level else {
            throw MandroidKitError.adb("Android did not apply the requested media volume")
        }
        return updated
    }

    public func forceStop(_ package: String) async throws {
        try await shell("am force-stop \(Self.shellQuote(package))")
    }

    public func install(apk: URL) async throws {
        try await run(["install", "-r", "-g", apk.path], timeout: .seconds(300))
    }

    public func uninstall(_ package: String) async throws {
        try await run(["uninstall", package], timeout: .seconds(120))
    }

    /// True if any task is currently hosted on the given logical display.
    public func hasTasks(onDisplay displayID: Int) async throws -> Bool {
        let out = try await shell("am stack list")
        // An empty answer means adb hiccupped, not that every task is gone.
        guard out.contains("RootTask") else { throw MandroidKitError.adb("empty task list") }
        return TaskListParser.displaysWithTasks(out).contains(displayID)
    }

    public func keyevent(_ key: String, displayID: Int? = nil) async throws {
        let d = displayID.map { "-d \($0) " } ?? ""
        try await shell("input \(d)keyevent \(Self.shellQuote(key))")
    }
}
