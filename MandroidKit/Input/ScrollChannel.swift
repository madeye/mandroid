import Foundation

/// Sends mouse-wheel events to Android through the long-running
/// `ScrollInjector` guest helper. The emulator's own wheel injection is
/// dropped on the phone image, and a synthesised touch drag becomes a click
/// wherever no scroll container intercepts it. If the helper dies it is
/// restarted on a later event.
public actor ScrollChannel {
    private let adb: ADBClient
    private var helper: ShellPipe?
    private var starting = false
    private var closed = false
    private var retryAfter = ContinuousClock.now

    public init(adb: ADBClient) { self.adb = adb }

    /// Starts the helper ahead of the first scroll (app_process takes ~0.5 s).
    public func start() async {
        guard !closed, !starting, helper?.isRunning != true, ContinuousClock.now >= retryAfter else { return }
        starting = true
        defer { starting = false }
        helper?.stop()
        helper = nil
        do {
            let started = try await adb.startScrollInjector()
            if closed { started.stop() } else { helper = started }
        } catch {
            Log.input.error("scroll helper unavailable: \(error.localizedDescription, privacy: .public)")
            retryAfter = ContinuousClock.now + .seconds(2)
        }
    }

    public func scroll(displayID: Int, x: Int, y: Int, axes: ScrollConverter.Axes) async {
        // Events that arrive while the helper (re)starts are dropped: sent
        // late, they would scroll after the user has stopped.
        guard let helper, helper.isRunning else { await start(); return }
        if !helper.write("\(displayID) \(x) \(y) \(axes.vertical) \(axes.horizontal)\n") {
            helper.stop()
            if self.helper === helper { self.helper = nil }
        }
    }

    public func close() {
        closed = true
        helper?.stop()
        helper = nil
    }
}
