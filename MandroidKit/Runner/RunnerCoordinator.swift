import Foundation
import Observation

/// Main-actor state machine that takes the app from "nothing installed" to a
/// booted emulator, and owns app sessions afterwards.
@MainActor
@Observable
public final class RunnerCoordinator {
    public private(set) var state: RunnerState = .idle {
        didSet {
            // Download progress ticks arrive every couple of MB; log each
            // component once instead of every tick.
            if case .settingUp(.downloading(let name, _)) = state {
                if case .settingUp(.downloading(let previous, _)) = oldValue, previous == name { return }
                Log.runner.notice("state → downloading \(name, privacy: .public)")
                Log.file("state → downloading \(name)", paths: paths)
                return
            }
            Log.runner.notice("state → \(String(describing: self.state).prefix(200), privacy: .public)")
            Log.file("state → \(String(describing: self.state).prefix(200))", paths: paths)
        }
    }
    public private(set) var session: EmulatorSession?
    public private(set) var sessions: [String: AppSession] = [:]   // by package
    /// Apps whose window is parked: the task still exists in Android (moved to
    /// display 0) but its slot has been released.
    public private(set) var parked: [String: AppSession] = [:]
    public private(set) var apps: [AppInfo] = []
    public var installedPackages: [String] { apps.map(\.package) }
    public private(set) var catalog: AppCatalog?
    public private(set) var clipboard: ClipboardSync?
    /// Set by the app to enable clipboard sync (needs AppKit's pasteboard).
    public var hostClipboard: (any HostClipboard)?

    public private(set) var appProxies: [String: HTTPProxyEndpoint] = [:]
    public private(set) var proxyError: String?
    private var savingProxy = false

    public let paths: SDKPaths
    public let bootstrap: SDKBootstrap
    public let avdStore: AVDStore
    public var avdName = "runner"

    private var bootTask: Task<Void, Never>?
    private var changingPackages = Set<String>()

    public init(paths: SDKPaths = .default) {
        self.paths = paths
        self.bootstrap = SDKBootstrap(paths: paths)
        self.avdStore = AVDStore(paths: paths)
        do { appProxies = try AppProxyStore.load(at: paths.root) }
        catch { proxyError = error.localizedDescription }
    }

    // MARK: Lifecycle

    /// Decides between setup and boot.
    public func start() {
        guard case .idle = state else { return }
        state = .checking
        bootTask = Task {
            defer { bootTask = nil }
            if bootstrap.isReady {
                await boot(coldBoot: false, isRetry: false)
            } else {
                do {
                    await bootstrap.setMirrors(RunnerSettings.load().mirrors)
                    let plan = try await bootstrap.makePlan()
                    try Task.checkCancellation()
                    if plan.isEmpty {
                        await boot(coldBoot: false, isRetry: false)
                    } else if UserDefaults.standard.bool(forKey: "autoSetup") {
                        // `-autoSetup YES` skips the confirmation (integration tests).
                        await performSetup(plan)
                    } else {
                        state = .needsSetup(plan)
                    }
                } catch {
                    if !Task.isCancelled { state = .failed(error.localizedDescription) }
                }
            }
        }
    }

    public func runSetup(_ plan: BootstrapPlan) {
        guard bootTask == nil else { return }
        bootTask = Task {
            defer { bootTask = nil }
            await performSetup(plan)
        }
    }

    private func performSetup(_ plan: BootstrapPlan) async {
        state = .settingUp(.fetchingManifests)
        do {
            try await bootstrap.run(plan) { phase in
                Task { @MainActor in
                    if case .settingUp = self.state { self.state = .settingUp(phase) }
                }
            }
            try Task.checkCancellation()
            await boot(coldBoot: false, isRetry: false)
        } catch {
            if !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }

    public func retry() {
        guard bootTask == nil else { return }
        state = .idle
        start()
    }

    private func setStage(_ s: String) {
        if case .shuttingDown = state { return }
        state = .booting(s)
    }

    public func boot(coldBoot: Bool = false) async {
        if let bootTask { await bootTask.value; return }
        let task = Task { await boot(coldBoot: coldBoot, isRetry: false) }
        bootTask = task
        await task.value
        bootTask = nil
    }

    private func boot(coldBoot: Bool, isRetry: Bool) async {
        guard session == nil else { return }
        var launched: EmulatorProcess?
        var startedADB: ADBClient?
        do {
            try Task.checkCancellation()
            setStage("Preparing virtual device")
            guard let image = bootstrap.installedSystemImage() else {
                throw MandroidKitError.avd("no system image installed")
            }
            var config = AVDConfig(systemImagePath: image.packagePath)
            config.name = avdName
            let settings = RunnerSettings.load()
            settings.apply(to: &config)
            // (Re)write the ini files every boot: picks up RAM/core changes and
            // drops hw.displayN.* keys the emulator persisted. User data and
            // snapshots live in other files and are untouched.
            let profileChanged = try avdStore.write(config)

            guard let console = PortAllocator.freeConsolePort(),
                  let grpc = PortAllocator.freePort(in: 8554...8654),
                  let adbPort = PortAllocator.freePort(in: 5137...5237) else {
                throw MandroidKitError.emulator("no free ports")
            }
            var options = EmulatorLaunchOptions(avdName: avdName, consolePort: console, grpcPort: grpc, adbServerPort: adbPort)
            options.coldBoot = coldBoot || profileChanged
            options.gpuBackend = settings.gpuBackend

            setStage("Starting adb")
            let adb = ADBClient(paths: paths, serverPort: adbPort, serial: options.serial)
            startedADB = adb
            try await adb.startServer()
            try Task.checkCancellation()

            setStage("Starting emulator")
            let process = try EmulatorProcess(paths: paths, options: options)
            try process.start()
            launched = process

            let connection = try EmulatorConnection(port: grpc)
            setStage("Connecting to emulator")
            do {
                try await connection.waitUntilReachable(timeout: .seconds(90))
            } catch {
                process.terminate()
                await adb.killServer()
                throw MandroidKitError.emulator("did not start:\n\(process.tailLog(lines: 12))")
            }

            try await BootWaiter.waitForBoot(adb: adb, process: process) { stage in
                let text: String
                switch stage {
                case .waitingForProcess, .waitingForADB: text = "Waiting for Android"
                case .waitingForBoot: text = "Android is booting"
                case .booted: text = "Finishing up"
                }
                Task { @MainActor in
                    if case .booting = self.state { self.setStage(text) }
                }
            }
            await GuestSetup.apply(adb: adb)
            await restoreAppProxies(adb: adb)
            if let volume = RunnerSettings.load().mediaVolumePercent {
                do { _ = try await adb.setMediaVolume(percent: volume) }
                catch { Log.file("Could not restore media volume: \(error.localizedDescription)", paths: paths) }
            }

            let client = EmulatorClient(connection: connection)
            let pool = DisplaySlotPool(client: client, adb: adb)
            try await pool.reset()

            let session = EmulatorSession(
                options: options, process: process, adb: adb, connection: connection, client: client,
                displays: pool, input: InputChannel(client: client), router: InputRouter(adb: adb),
                frames: GRPCFrameStream(client: client),
                deviceWidth: config.lcdWidth, deviceHeight: config.lcdHeight, deviceDpi: config.lcdDensity)
            var sync: ClipboardSync?
            if let hostClipboard {
                let clipboard = ClipboardSync(client: client, host: hostClipboard)
                await clipboard.start()
                sync = clipboard
            }
            if Task.isCancelled {
                await sync?.stop()
                throw CancellationError()
            }
            self.session = session
            self.catalog = AppCatalog(paths: paths, adb: adb, mirrors: RunnerSettings.load().mirrors)
            self.clipboard = sync
            state = .ready
            watchProcess(session)
            await refreshApps()
        } catch {
            Log.runner.error("boot failed: \(error.localizedDescription)")
            Log.file("boot failed: \(error.localizedDescription.prefix(300))", paths: paths)
            if let launched {
                launched.terminate()
                _ = await launched.waitForExit(timeout: .seconds(5))
                launched.kill()
            }
            // Cleanup must run outside the cancelled startup task.
            if let startedADB { await Task.detached { await startedADB.killServer() }.value }
            if Task.isCancelled { return }
            // An emulator that dies during boot is almost always a bad quickboot
            // snapshot (e.g. the previous run was killed while saving it). Drop
            // the snapshot and cold boot once before giving up.
            let message = error.localizedDescription
            if !isRetry, message.contains("exited during boot") {
                if message.contains("snapshot") { avdStore.deleteQuickbootSnapshot(avdName) }
                Log.file("boot: retrying with a cold boot", paths: paths)
                await boot(coldBoot: true, isRetry: true)
                return
            }
            state = .failed(message)
        }
    }

    private func watchProcess(_ session: EmulatorSession) {
        Task {
            let status = await session.process.waitForExit()
            guard self.session?.process === session.process else { return }
            if case .shuttingDown = state { return }
            await clipboard?.stop()
            clipboard = nil
            await session.input.close()
            session.connection.shutdown()
            await session.adb.killServer()
            guard self.session?.process === session.process else { return }
            refreshTask?.cancel()
            catalog = nil
            apps = []
            self.session = nil
            self.sessions = [:]
            self.parked = [:]
            if case .shuttingDown = state { state = .idle } else {
                state = .failed("The emulator stopped unexpectedly (exit code \(status)).")
            }
        }
    }

    /// Clean shutdown: stop apps, ask QEMU to power off (saves the quickboot
    /// snapshot), then escalate to SIGTERM/SIGKILL. Never leaves an orphan.
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await performShutdown() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private var shutdownTask: Task<Void, Never>?

    private func performShutdown() async {
        state = .shuttingDown
        bootTask?.cancel()
        await bootTask?.value
        bootTask = nil
        refreshTask?.cancel()
        catalog = nil
        guard let session else { apps = []; state = .idle; return }
        await clipboard?.stop()
        clipboard = nil
        await session.input.close()
        try? await session.displays.reset()
        // Ask QEMU to power off over gRPC (adb "emu kill" needs the console
        // auth token and silently does nothing without it). The emulator saves
        // the quickboot snapshot on the way out, which takes several seconds
        // for a 4 GB guest, so wait generously before escalating: a SIGKILL
        // during the save leaves a snapshot the next boot cannot load.
        _ = try? await session.client.requestShutdown()
        var exited = await session.process.waitForExit(timeout: .seconds(60))
        if !exited {
            Log.file("shutdown: emulator still running after 60 s, sending SIGTERM", paths: paths)
            session.process.terminate()
            exited = await session.process.waitForExit(timeout: .seconds(30))
        }
        if !exited {
            Log.file("shutdown: emulator ignored SIGTERM, killing", paths: paths)
            session.process.kill()
        }
        await session.adb.killServer()
        session.connection.shutdown()
        self.session = nil
        self.sessions = [:]
        self.parked = [:]
        self.apps = []
        state = .idle
    }

    // MARK: Apps

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()

    /// Reloads the app list: cached entries immediately, then labels/icons
    /// for anything new as they resolve.
    public func refreshApps() async {
        guard let catalog else { return }
        let generation = UUID()
        refreshGeneration = generation
        refreshTask?.cancel()
        let quick = try? await catalog.cached()
        guard refreshGeneration == generation, state.isReady else { return }
        if let quick { apps = quick }
        refreshTask = Task { [weak self] in
            do {
                _ = try await catalog.refresh { list in
                    Task { @MainActor in
                        guard let self, self.refreshGeneration == generation, self.state.isReady else { return }
                        self.apps = list
                    }
                }
            } catch {
                Log.runner.warning("catalog refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// Kept for callers that only need package names.
    public func refreshInstalledPackages() async { await refreshApps() }

    public func app(for package: String) -> AppInfo? { apps.first { $0.package == package } }

    private func launcherComponent(for package: String) async throws -> String {
        if let c = app(for: package)?.launcherComponent { return c }
        guard let session, let c = try await session.adb.launcherComponent(of: package) else {
            throw MandroidKitError.adb("\(package) has no launcher activity")
        }
        return c
    }

    /// Creates a display and launches (or brings back) the app on it.
    public func openApp(package: String, width: Int, height: Int, dpi: Int) async throws -> AppSession {
        if let proxyError { throw MandroidKitError.adb("App HTTP proxies are not active: \(proxyError)") }
        guard state.isReady, let session else { throw MandroidKitError.emulator("not running") }
        guard !changingPackages.contains(package) else { throw MandroidKitError.display("app operation already in progress") }
        if let existing = sessions[package] { return existing }
        changingPackages.insert(package)
        defer { changingPackages.remove(package) }
        let component = try await launcherComponent(for: package)
        do {
            try await session.adb.useWindowOrientation(for: package)
        } catch {
            // Older images or apps that reject overrides can still launch
            // with Android's original compatibility layout.
            Log.runner.warning("window orientation override for \(package) failed: \(error.localizedDescription)")
        }
        let slot: DisplaySlot
        do {
            slot = try await session.displays.acquire(width: width, height: height, dpi: dpi)
        } catch {
            Log.file("openApp \(package): acquire failed: \(error.localizedDescription)", paths: paths)
            throw error
        }
        do {
            try await session.adb.startActivity(component: component, displayID: slot.androidDisplayID)
            try Task.checkCancellation()
            guard self.session?.process === session.process, state.isReady else {
                throw MandroidKitError.emulator("session ended while opening app")
            }
        } catch {
            Log.file("openApp \(package): am start failed: \(error.localizedDescription)", paths: paths)
            try? await session.displays.release(slot.emulatorIndex)
            throw error
        }
        Log.file("openApp \(package) → slot \(slot.emulatorIndex) display \(slot.androidDisplayID) \(slot.width)x\(slot.height)", paths: paths)
        await session.router.noteTouch(androidDisplayID: slot.androidDisplayID)
        let app = AppSession(package: package, launcherComponent: component, slot: slot)
        sessions[package] = app
        parked[package] = nil
        return app
    }

    /// Frees the slot but keeps the Android task alive (it moves to display 0).
    public func parkApp(_ app: AppSession) async {
        guard let session, sessions[app.package]?.instanceID == app.instanceID else { return }
        sessions[app.package] = nil
        parked[app.package] = app
        try? await session.displays.release(app.slot.emulatorIndex)
        await session.router.forget(androidDisplayID: app.slot.androidDisplayID)
    }

    public var freeSlots: Int {
        DisplaySlotPool.capacity - sessions.count
    }

    public func closeApp(_ app: AppSession) async {
        guard let session else { return }
        let active = sessions[app.package]
        guard active?.instanceID == app.instanceID || parked[app.package]?.instanceID == app.instanceID,
              !changingPackages.contains(app.package) else { return }
        changingPackages.insert(app.package)
        defer { changingPackages.remove(app.package) }
        sessions[app.package] = nil
        parked[app.package] = nil
        try? await session.adb.forceStop(app.package)
        // A parked window's old index may now belong to another app.
        if let active {
            try? await session.displays.release(active.slot.emulatorIndex)
            await session.router.forget(androidDisplayID: active.slot.androidDisplayID)
        }
    }

    /// True while Android still hosts a task on the app's display.
    public func isAppAlive(_ app: AppSession) async -> Bool {
        guard let session else { return false }
        return (try? await session.adb.hasTasks(onDisplay: app.slot.androidDisplayID)) ?? true
    }

    public func resizeApp(_ app: AppSession, width: Int, height: Int, dpi: Int) async throws -> AppSession {
        guard let session, sessions[app.package]?.instanceID == app.instanceID else {
            throw MandroidKitError.emulator("app session ended")
        }
        let slot = try await session.displays.resize(app.slot.emulatorIndex, width: width, height: height, dpi: dpi)
        var updated = app
        updated.slot = slot
        if sessions[app.package]?.instanceID == app.instanceID { sessions[app.package] = updated }
        return updated
    }

    private func restoreAppProxies(adb: ADBClient) async {
        do {
            appProxies = try AppProxyStore.load(at: paths.root)
            try await adb.applyAppProxies(appProxies)
            proxyError = nil
        } catch {
            proxyError = error.localizedDescription
        }
    }

    public func setHTTPProxy(_ proxy: HTTPProxyEndpoint?, for package: String) async throws {
        guard !savingProxy else { throw MandroidKitError.adb("Another proxy change is still being applied") }
        savingProxy = true
        defer { savingProxy = false }
        var next = appProxies
        next[package] = proxy
        let adb = session?.adb
        if let adb { try await adb.applyAppProxies(next) }
        do { try AppProxyStore.save(next, at: paths.root) }
        catch {
            if let adb { try? await adb.applyAppProxies(appProxies) }
            throw error
        }
        appProxies = next
        proxyError = nil
    }

    public func installAPK(_ url: URL) async throws {
        guard let session else { throw MandroidKitError.emulator("not running") }
        try await session.adb.install(apk: url)
        await restoreAppProxies(adb: session.adb)
        await refreshApps()
    }

    public func uninstall(package: String) async throws {
        guard let session else { throw MandroidKitError.emulator("not running") }
        if let app = sessions[package] ?? parked[package] { await closeApp(app) }
        try await session.adb.uninstall(package)
        if appProxies[package] != nil { try await setHTTPProxy(nil, for: package) }
        await catalog?.invalidate(package: package)
        await refreshApps()
    }

    /// Saves a PNG of the given display to `url`.
    public func screenshot(display: Int, width: Int, height: Int) async throws -> Frame {
        guard let session else { throw MandroidKitError.emulator("not running") }
        let img = try await session.client.screenshot(display: display, width: width, height: height)
        return Frame(width: Int(img.format.width), height: Int(img.format.height), pixels: img.image,
                     sequence: img.seq, timestampUs: img.timestampUs)
    }

    /// Restarts the emulator (cold boot when requested).
    private var restarting = false

    public func restart(coldBoot: Bool = false) async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        await shutdown()
        await boot(coldBoot: coldBoot)
    }

    /// Opens the Play Store on the device screen (display 0).
    public func openPlayStore() async {
        guard let session else { return }
        _ = try? await session.adb.shell("am start --display 0 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n com.android.vending/.AssetBrowserActivity")
    }
}
