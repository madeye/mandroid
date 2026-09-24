import AppKit
import MandroidKit

/// One macOS window showing one emulator display: either an app on a
/// secondary display or the built-in device screen (display 0).
final class AppWindowController: NSWindowController, NSWindowDelegate {
    enum Target {
        case app(AppSession)
        case device
    }

    let coordinator: RunnerCoordinator
    private(set) var target: Target
    var onClose: (() -> Void)?

    private let frameView = FrameView(frame: .zero)
    private var frameTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var resizePending = false
    private var isClosing = false
    private var isResuming = false
    private var watchdog: Task<Void, Never>?
    private var overlay: ParkedOverlayView?
    private(set) var isParked = false
    /// Last time this window became key; used for LRU parking.
    private(set) var lastActivated = Date()
    var onActivated: (() -> Void)?
    /// Called before resuming a parked window so the window manager can park
    /// another window if all slots are taken.
    var makeRoom: (() async throws -> Void)?

    var emulatorDisplay: Int {
        if case .app(let s) = target { return s.slot.emulatorIndex } else { return 0 }
    }
    var androidDisplayID: Int {
        if case .app(let s) = target { return s.slot.androidDisplayID } else { return 0 }
    }
    private var pixelSize: (Int, Int) {
        switch target {
        case .app(let s): return (s.slot.width, s.slot.height)
        case .device: return (coordinator.session?.deviceWidth ?? 2560, coordinator.session?.deviceHeight ?? 1600)
        }
    }

    init(coordinator: RunnerCoordinator, target: Target, logicalSize: NSSize) {
        self.coordinator = coordinator
        self.target = target
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: logicalSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 320, height: 320)
        window.backgroundColor = .black
        window.contentView = frameView
        super.init(window: window)
        window.delegate = self
        switch target {
        case .app(let s):
            window.title = coordinator.app(for: s.package)?.label ?? Self.displayName(for: s.package)
            if !UITestMode.enabled { window.setFrameAutosaveName("app:\(s.package)") }
        case .device:
            window.title = "Device Screen"
            if !UITestMode.enabled { window.setFrameAutosaveName("device") }
            window.contentAspectRatio = logicalSize
        }
        if window.frame.origin == .zero { window.center() }
        frameView.frame = window.contentView!.bounds
        configureInput()
        startFrames()
        startWatchdog()
        scheduleReconfigure() // Apply a restored window size to the guest too.
    }

    var package: String? { if case .app(let s) = target { return s.package } else { return nil } }

    required init?(coder: NSCoder) { fatalError() }

    static func displayName(for package: String) -> String {
        // Phase 2 replaces this with aapt2 labels.
        let last = package.split(separator: ".").last.map(String.init) ?? package
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: Input plumbing

    private func configureInput() {
        let (w, h) = pixelSize
        frameView.displayWidth = w
        frameView.displayHeight = h
        switch target {
        case .app(let app): frameView.displayDpi = app.slot.dpi
        case .device: frameView.displayDpi = coordinator.session?.deviceDpi ?? 320
        }
        frameView.onTouch = { [weak self] x, y, id, pressure in
            guard let self, !isParked, !isClosing, let session = coordinator.session else { return }
            let display = emulatorDisplay
            Task { await session.input.touch(display: display, x: x, y: y, identifier: id, pressure: pressure) }
        }
        frameView.onScroll = { [weak self] x, y, axes in
            guard let self, !isParked, !isClosing, let session = coordinator.session else { return }
            let display = androidDisplayID
            Task { await session.scroll.scroll(displayID: display, x: x, y: y, axes: axes) }
        }
        frameView.onFirstTouch = { [weak self] in
            guard let self, !isParked, !isClosing, let session = coordinator.session else { return }
            let id = androidDisplayID
            Task { await session.router.noteTouch(androidDisplayID: id) }
        }
        frameView.onKey = { [weak self] action in
            guard let self, !isParked, !isClosing, let session = coordinator.session else { return }
            Task {
                await self.ensureFocus()
                await session.input.perform(action)
            }
        }
    }

    private func ensureFocus() async {
        guard !isParked, !isClosing, let session = coordinator.session else { return }
        switch target {
        case .app(let s): await session.router.ensureKeyboardFocus(on: s)
        case .device: await session.router.ensureKeyboardFocusOnDeviceScreen()
        }
    }

    // MARK: Frames

    private func startFrames() {
        frameTask?.cancel()
        guard !framesPaused, !isParked, !isClosing, let session = coordinator.session else { return }
        let display = emulatorDisplay
        let (w, h) = pixelSize
        let stream = session.frames
        frameTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    for try await frame in stream.frames(display: display, width: w, height: h) {
                        if Task.isCancelled { return }
                        self?.frameView.display(frame)
                    }
                    return
                } catch {
                    attempt += 1
                    Log.ui.warning("frame stream for display \(display) failed: \(error.localizedDescription)")
                    if attempt > 5 { return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }

    // MARK: Liveness

    /// Closes the window when Android no longer hosts a task on our display
    /// (the app finished itself, e.g. Back on its root activity).
    private func startWatchdog() {
        watchdog?.cancel()
        guard case .app = target else { return }
        watchdog = Task { [weak self] in
            var misses = 0
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                guard let self, !self.isParked, case .app(let app) = self.target else { return }
                let alive = await self.coordinator.isAppAlive(app)
                misses = alive ? 0 : misses + 1
                if misses >= 3 {
                    Log.ui.info("\(app.package) left its display; closing window")
                    self.window?.close()
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Parking

    /// Keeps the last frame on screen behind an overlay and releases the
    /// display slot. The Android task survives on display 0.
    func park() async {
        guard case .app(let app) = target, !isParked else { return }
        isParked = true
        resizePending = false
        await resizeTask?.value
        frameTask?.cancel(); frameTask = nil
        watchdog?.cancel(); watchdog = nil
        await coordinator.parkApp(app)
        let ov = ParkedOverlayView(frame: frameView.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.onResume = { [weak self] in self?.resume() }
        frameView.addSubview(ov)
        overlay = ov
        ov.appear()
        if window?.isKeyWindow == true { window?.makeFirstResponder(ov) }
        window?.title = (coordinator.app(for: app.package)?.label ?? Self.displayName(for: app.package)) + " (paused)"
    }

    func resume() {
        guard case .app(let app) = target, isParked, !isResuming, !isClosing, let window else { return }
        isResuming = true
        overlay?.setResuming(true)
        Task { @MainActor in
            defer { isResuming = false }
            let scale = window.backingScaleFactor
            let size = frameView.bounds.size
            do {
                try await makeRoom?()
                guard !isClosing else { return }
                let fresh = try await coordinator.openApp(package: app.package,
                                                          width: Int(size.width * scale), height: Int(size.height * scale),
                                                          dpi: Int(160 * scale))
                guard !isClosing else { await coordinator.closeApp(fresh); return }
                target = .app(fresh)
                isParked = false
                overlay?.removeFromSuperview(); overlay = nil
                window.title = coordinator.app(for: app.package)?.label ?? Self.displayName(for: app.package)
                configureInput()
                window.makeFirstResponder(frameView)
                startFrames()
                startWatchdog()
            } catch {
                overlay?.setResuming(false, error: "Could not resume. \(error.localizedDescription)")
                Log.ui.error("resume failed: \(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        lastActivated = Date()
        onActivated?()
        window?.makeFirstResponder(isParked ? overlay : frameView)
        guard !isParked else { return }
        Task {
            // When the activation came from a click, the touch itself moves
            // Android's focus to this display a few ms from now. Wait for it
            // so the nudge (an `am start` that re-delivers the launcher
            // intent) is skipped: some games drop a touch that arrives during
            // that resume cycle. Keys call ensureFocus() themselves.
            try? await Task.sleep(for: .milliseconds(300))
            guard window?.isKeyWindow == true else { return }
            await ensureFocus()
            await coordinator.clipboard?.pushHostClipboard()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard case .app = target, !isParked else { return }
        scheduleReconfigure()
    }

    func windowDidResize(_ notification: Notification) {
        guard case .app = target, !isParked else { return }
        scheduleReconfigure()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard case .app = target else { return }
        scheduleReconfigure()
    }

    /// Coalesce drag events while allowing only one guest reconfiguration at
    /// a time. Cancelling a request after it reaches the emulator can leave
    /// our slot and screenshot stream at the previous resolution.
    private func scheduleReconfigure() {
        guard case .app = target, !isParked, !isClosing else { return }
        resizePending = true
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self] in
            guard let self else { return }
            defer { resizeTask = nil }
            while resizePending, !isParked, !isClosing {
                try? await Task.sleep(for: .milliseconds(150))
                guard !isParked, !isClosing, let window, case .app(let app) = target else { return }
                resizePending = false
                let scale = window.backingScaleFactor
                let size = frameView.bounds.size
                let (w, h, dpi) = DisplaySlotPool.sanitize(
                    width: Int((size.width * scale).rounded()),
                    height: Int((size.height * scale).rounded()), dpi: Int(160 * scale))
                guard w != app.slot.width || h != app.slot.height || dpi != app.slot.dpi else { continue }
                do {
                    let updated = try await coordinator.resizeApp(app, width: w, height: h, dpi: dpi)
                    guard !isParked, !isClosing else { return }
                    target = .app(updated)
                    configureInput()
                    startFrames()
                } catch {
                    Log.ui.error("resize failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { pauseFrames() }
    func windowDidDeminiaturize(_ notification: Notification) { resumeFrames() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        if window.occlusionState.contains(.visible) { resumeFrames() } else { pauseFrames() }
    }

    private var framesPaused = false
    private func pauseFrames() {
        guard !UITestMode.enabled, !framesPaused, !isParked else { return }
        framesPaused = true
        frameTask?.cancel(); frameTask = nil
    }
    private func resumeFrames() {
        guard framesPaused, !isParked else { return }
        framesPaused = false
        startFrames()
    }

    func windowWillClose(_ notification: Notification) {
        frameTask?.cancel()
        isClosing = true
        resizePending = false
        watchdog?.cancel()
        if case .app(let app) = target {
            Task {
                await resizeTask?.value
                await coordinator.closeApp(app)
            }
        }
        onClose?()
    }

    // MARK: Menu actions

    @objc func androidBack(_ sender: Any?) { sendKey(.key("GoBack")) }
    @objc func androidHome(_ sender: Any?) { sendKey(.key("GoHome")) }
    @objc func androidRecents(_ sender: Any?) { sendKey(.key("AppSwitch")) }

    /// ⌘R: swaps the window's width and height. The debounced resize path then
    /// reconfigures the virtual display in place, so the app relays out for
    /// the new orientation without restarting.
    @objc func rotateWindow(_ sender: Any?) {
        guard case .app = target, !isParked, let window else { NSSound.beep(); return }
        let content = window.contentRect(forFrameRect: window.frame)
        let chrome = window.frame.height - content.height
        var size = NSSize(width: content.height, height: content.width)
        let screen = window.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let maxW = visible.width - 16, maxH = visible.height - chrome - 16
            let f = min(1, maxW / size.width, maxH / size.height)
            size = NSSize(width: (size.width * f).rounded(), height: (size.height * f).rounded())
        }
        // Keep the top-left corner, then pull the whole window back on screen.
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen { frame = window.constrainFrameRect(frame, to: screen) }
        window.setFrame(frame, display: true, animate: !HostStyle.reduceMotion)
        scheduleReconfigure()
    }

    /// ⇧⌘S: saves the current display as PNG on the Desktop.
    @objc func saveScreenshot(_ sender: Any?) {
        guard !isParked, !isClosing else { return }
        let (w, h) = pixelSize
        let display = emulatorDisplay
        let name = (package.map { coordinator.app(for: $0)?.label ?? $0 } ?? "Device Screen")
        Task {
            do {
                let frame = try await coordinator.screenshot(display: display, width: w, height: h)
                guard let png = FrameView.pngData(frame) else { return }
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                let url = dir.appendingPathComponent("\(name) \(stamp).png")
                try png.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                Log.ui.error("screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendKey(_ action: KeyAction) {
        guard !isParked, !isClosing, let session = coordinator.session else { return }
        Task {
            await ensureFocus()
            await session.input.perform(action)
        }
    }
}
