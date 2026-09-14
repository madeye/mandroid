import MandroidKit
import SwiftUI

struct SettingsView: View {
    let coordinator: RunnerCoordinator
    let windows: WindowManager
    @State private var settings = RunnerSettings.load()
    @State private var saved = RunnerSettings.load()
    @State private var volume: Double = 0
    @State private var volumeReady = false
    @State private var applyingVolume = false
    @State private var volumeError: String?


    private var needsRestart: Bool { settings.ramMB != saved.ramMB || settings.cores != saved.cores || settings.gpuBackend != saved.gpuBackend }

    var body: some View {
        Form {
            Section("Virtual device") {
                Picker("Memory", selection: $settings.ramMB) {
                    ForEach(RunnerSettings.ramChoices, id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                }
                Picker("CPU cores", selection: $settings.cores) {
                    ForEach(RunnerSettings.coreChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Graphics", selection: $settings.gpuBackend) {
                    ForEach(GPUBackend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if needsRestart {
                    Text("Takes effect after the emulator restarts.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Restart Emulator") { restart(cold: false) }
                    Button("Cold Boot") { restart(cold: true) }
                }
            }
            Section("Audio") {
                HStack {
                    Slider(value: $volume, in: 0...100, step: 1, label: { Text("Media volume") }, onEditingChanged: { editing in
                        if !editing { applyVolume() }
                    })
                    .disabled(!volumeReady || applyingVolume || !coordinator.state.isReady)
                    Text(volumeReady ? "\(Int(volume))%" : "—")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("Controls all Android apps. Changes apply immediately; 0% mutes media audio.")
                    .font(.caption).foregroundStyle(.secondary)
                if !coordinator.state.isReady {
                    Text("Available when Android is running.").font(.caption).foregroundStyle(.secondary)
                }
                if let volumeError { Text(volumeError).font(.caption).foregroundStyle(.red) }
            }
            Section("Windows") {
                Picker("New windows open", selection: $settings.landscapeByDefault) {
                    Text("Landscape").tag(true)
                    Text("Portrait").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper("Default window height: \(settings.defaultWindowHeight) pt",
                        value: $settings.defaultWindowHeight, in: 500...1600, step: 50)
                Toggle("Create launcher stubs in ~/Applications/Android Apps", isOn: $settings.launcherStubs)
                Text("Stubs let Android apps appear in Spotlight and the Dock.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Picker("Download SDK from", selection: $settings.downloadMirror) {
                    Text("Automatic").tag(DownloadMirror.Preference.auto)
                    Text(DownloadMirror.google.name).tag(DownloadMirror.Preference.google)
                    Text(DownloadMirror.china.name).tag(DownloadMirror.Preference.china)
                }
                Text("Automatic uses the China mirror only when this Mac's region or time zone is mainland China. Applies to the next download.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Files") {
                LabeledContent("System image") {
                    Text(coordinator.bootstrap.installedSystemImage()?.packagePath ?? "none").textSelection(.enabled)
                }
                HStack {
                    Button("Show Logs") { NSWorkspace.shared.open(coordinator.paths.logs) }
                    Button("Show Data Folder") { NSWorkspace.shared.open(coordinator.paths.root) }
                }
                Text("Data folder: \(coordinator.paths.root.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        // A grouped Form has no intrinsic height (it is a scroll view), so the
        // hosting window would collapse to zero height without an explicit size.
        .frame(width: 500, height: 780)
        .task(id: coordinator.state.isReady) {
            volumeReady = false
            guard coordinator.state.isReady, let adb = coordinator.session?.adb else { return }
            do {
                volume = Double(try await adb.mediaVolume().percent)
                volumeReady = true
                volumeError = nil
            } catch { volumeError = error.localizedDescription }
        }
        .onChange(of: settings) { _, new in
            new.save()
            if !new.launcherStubs {
                LauncherStubBuilder.sync([])
            } else if !coordinator.apps.isEmpty {
                LauncherStubBuilder.sync(coordinator.apps)
            }
        }
    }

    private func applyVolume() {
        guard volumeReady, !applyingVolume, let adb = coordinator.session?.adb else { return }
        applyingVolume = true
        let requested = Int(volume)
        Task {
            defer { applyingVolume = false }
            do {
                let actual = try await adb.setMediaVolume(percent: requested)
                volume = Double(actual.percent)
                settings.mediaVolumePercent = actual.percent
                volumeError = nil
            } catch { volumeError = error.localizedDescription }
        }
    }

    private func restart(cold: Bool) {
        saved = settings
        windows.closeAll()
        Task { await coordinator.restart(coldBoot: cold) }
    }
}

final class SettingsWindowController: NSWindowController {
    init(coordinator: RunnerCoordinator, windows: WindowManager) {
        let host = NSHostingController(rootView: SettingsView(coordinator: coordinator, windows: windows))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError() }
}
