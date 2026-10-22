import Foundation
import Testing
@testable import MandroidKit

@Suite struct GuestSessionCapabilitiesTests {
    @Test func plainShellAsRootMeansAdbRoot() {
        #expect(GuestSessionCapabilities.classify(idOutput: "uid=0(root) gid=0(root) context=u:r:shell:s0", suOutput: nil) == .adbRoot)
    }

    @Test func rootOnlyThroughSuMeansKernelSUShellRoot() {
        let id = "uid=2000(shell) gid=2000(shell) context=u:r:shell:s0"
        let su = "uid=0(root) gid=0(root) context=u:r:ksu:s0"
        #expect(GuestSessionCapabilities.classify(idOutput: id, suOutput: su) == .kernelSUShellRoot)
    }

    @Test func neitherRouteMeansNone() {
        let id = "uid=2000(shell) gid=2000(shell) context=u:r:shell:s0"
        #expect(GuestSessionCapabilities.classify(idOutput: id, suOutput: "su: inaccessible or not found") == .none)
        #expect(GuestSessionCapabilities.classify(idOutput: id, suOutput: nil) == .none)
    }

    @Test func writableSystemAppearsInLaunchArguments() {
        var options = EmulatorLaunchOptions(avdName: "runner", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
        options.writableSystem = true
        #expect(options.arguments.contains("-writable-system"))
        options.writableSystem = false
        #expect(!options.arguments.contains("-writable-system"))
    }

    @Test func writableSystemSettingRoundTrips() throws {
        let suite = "writable-system-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = RunnerSettings.load(from: defaults)
        #expect(!settings.writableSystemEnabled)
        settings.writableSystemEnabled = true
        settings.save(to: defaults)
        #expect(RunnerSettings.load(from: defaults).writableSystemEnabled)
    }

    @Test func writableSystemSettingReachesLaunchArgumentsAndAsksForARestart() {
        let stock = RunnerSettings()
        var writable = stock
        writable.writableSystemEnabled = true
        var options = EmulatorLaunchOptions(avdName: "runner", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
        stock.apply(to: &options)
        #expect(!options.arguments.contains("-writable-system"))
        writable.apply(to: &options)
        #expect(options.arguments.contains("-writable-system"))
        #expect(writable.requiresRestart(comparedTo: stock))
        #expect(stock.requiresRestart(comparedTo: writable))
    }

    @Test func writableSystemRecordIsReappliedOnlyWithARootShell() {
        let installation = captureInstallation(backend: .writableSystem)
        #expect(GuestSessionCapabilities.adbRoot.shouldReapply(installation))
        // A KernelSU session reaches root through `su`; the shell is not root,
        // so it cannot rebuild the store the writable-system path installs.
        #expect(!GuestSessionCapabilities.kernelSUShellRoot.shouldReapply(installation))
        #expect(!GuestSessionCapabilities.none.shouldReapply(installation))
    }

    @Test func moduleRecordAndMissingRecordAreNotReapplied() {
        #expect(!GuestSessionCapabilities.adbRoot.shouldReapply(captureInstallation(backend: .kernelSUModule)))
        #expect(!GuestSessionCapabilities.adbRoot.shouldReapply(nil))
    }

    private func captureInstallation(backend: CaptureBackend) -> CaptureInstallation {
        CaptureInstallation(fileName: "c76e9e25.0", subject: "Capture CA", notAfter: Date(),
                            backend: backend, installedAt: Date())
    }
}
