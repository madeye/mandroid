import Foundation
import Testing
@testable import MandroidKit

@Suite struct GPUBackendTests {
    @Test func settingsReachBothAVDAndLaunchArguments() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        for backend in GPUBackend.allCases {
            var settings = RunnerSettings()
            settings.gpuBackend = backend
            settings.save(to: defaults)
            let loaded = RunnerSettings.load(from: defaults)
            var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
            loaded.apply(to: &config)
            var options = EmulatorLaunchOptions(avdName: "test", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
            options.gpuBackend = loaded.gpuBackend
            #expect(config.gpuBackend == backend)
            #expect(config.gpuMode == backend.emulatorMode)
            let gpuIndex = try #require(options.arguments.firstIndex(of: "-gpu"))
            #expect(options.arguments[gpuIndex + 1] == config.gpuMode)
            let featureIndex = try #require(options.arguments.firstIndex(of: "-feature"))
            #expect(options.arguments[featureIndex + 1] == backend.emulatorFeatures)
        }
        defaults.set("unknown", forKey: "gpuBackend")
        #expect(RunnerSettings.load(from: defaults).gpuBackend == RunnerSettings().gpuBackend)
    }

    @Test func experimentalOverridesAreNotInherited() {
        let original = ["PATH": "/usr/bin", "ANDROID_EGL_ON_EGL": "1", "ANGLE_DEFAULT_PLATFORM": "metal",
                        "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "0", "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS": "1"]
        for backend in GPUBackend.allCases {
            let env = backend.environment(from: original)
            #expect(env["ANDROID_EGL_ON_EGL"] == nil)
            #expect(env["ANGLE_DEFAULT_PLATFORM"] == nil)
            #expect(env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] == nil)
            #expect(env["MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"] == nil)
            #expect(env["PATH"] == "/usr/bin")
        }
    }

    @Test func switchingGraphicsInvalidatesSnapshotWithoutDeletingUserData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AVDStore(paths: SDKPaths(root: root))
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        config.gpuBackend = .host
        #expect(try store.write(config) == false)
        let userdata = store.directory(for: config.name).appendingPathComponent("userdata-qemu.img")
        try Data("preserve".utf8).write(to: userdata)
        #expect(try store.write(config) == false)
        // Both hardware profiles use -gpu host but require separate snapshots.
        config.gpuBackend = .hostBatched
        #expect(try store.write(config))
        #expect(try store.write(config) == false)
        config.gpuBackend = .software
        #expect(try store.write(config))
        #expect(try store.write(config) == false)
        config.gpuBackend = .host
        #expect(try store.write(config))
        #expect(try Data(contentsOf: userdata) == Data("preserve".utf8))
    }
}
