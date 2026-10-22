import MandroidKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let coordinator: RunnerCoordinator
    let windows: WindowManager
    @State private var settings = RunnerSettings.load()
    @State private var saved = RunnerSettings.load()
    @State private var volume: Double = 0
    @State private var volumeReady = false
    @State private var applyingVolume = false
    @State private var volumeError: String?
    @State private var pasteText = ""
    @State private var proxyText = ""
    @State private var captureState: CaptureControllerState = .idle
    @State private var captureVerdict: ChainVerdict?
    @State private var captureError: String?
    @State private var captureBusy = false
    @State private var imageDownload: ImageDownload = .idle
    @State private var imageNotice: String?


    private var needsRestart: Bool {
        if let session = coordinator.session {
            if (session.options.kernelSURamdisk != nil) != settings.kernelSUEnabled { return true }
            // Installing a capture certificate needs a session booted from a
            // shell-rooted patch, which is the choice recorded on its ramdisk.
            // Only a KernelSU patch can carry that choice, so a restart is only
            // pending while KernelSU is on: with it off, no patch is prepared
            // and no restart can satisfy the request.
            if settings.kernelSUEnabled,
               KernelSUPatcher.allowsShell(ramdisk: session.options.kernelSURamdisk) != settings.captureCertificateEnabled { return true }
            let display = settings.deviceDisplay
            if session.deviceWidth != display.widthPixels || session.deviceHeight != display.heightPixels
                || session.deviceDpi != display.density { return true }
        }
        return settings.requiresRestart(comparedTo: saved)
    }

    var body: some View {
        Form {
            Section("Virtual device") {
                Picker("Device screen profile", selection: $settings.deviceProfile) {
                    ForEach(DeviceProfile.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if settings.deviceProfile == .custom {
                    Stepper("Width: \(settings.customDeviceWidthDP) dp", value: $settings.customDeviceWidthDP,
                            in: DeviceDisplay.dimensionRange, step: 20)
                    Stepper("Height: \(settings.customDeviceHeightDP) dp", value: $settings.customDeviceHeightDP,
                            in: DeviceDisplay.dimensionRange, step: 20)
                    Stepper("Density: \(settings.customDeviceDensity) dpi", value: $settings.customDeviceDensity,
                            in: DeviceDisplay.densityRange, step: 20)
                }
                Text(settings.deviceDisplay.summary).font(.caption).foregroundStyle(.secondary)
                Text("Open Device Screen to test apps with this display profile. Separate app windows use their own window size.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    HostNotice(message: "Changes saved. Restart the emulator to apply them.", symbol: "arrow.clockwise.circle")
                        .transition(.opacity)
                }
                HStack {
                    Button("Restart Emulator") { restart(cold: false) }
                    Button("Cold Boot") { restart(cold: true) }
                }
            }
            Section("KernelSU (experimental)") {
                Toggle("Boot with KernelSU", isOn: $settings.kernelSUEnabled)
                Text("Adds root support to the supported Android 36.1 ARM64 image. A separate patched image preserves the stock image. Turn this off and restart to return to stock; installed apps and data are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.session?.options.kernelSURamdisk != nil {
                    Label("KernelSU is active", systemImage: "checkmark.circle")
                } else {
                    Text("KernelSU is not active in this session.").font(.caption).foregroundStyle(.secondary)
                }
                Text(coordinator.kernelSUStatus).font(.caption).foregroundStyle(.secondary)
                if let error = coordinator.kernelSUError { HostNotice(message: error) }
                HStack {
                    if coordinator.preparingKernelSU {
                        ProgressView().controlSize(.small)
                        Button("Cancel Preparation") { coordinator.cancelKernelSUPreparation() }
                    } else {
                        Button("Prepare Patched Image") {
                            Task { _ = try? await coordinator.prepareKernelSU() }
                        }
                        .disabled(!coordinator.bootstrap.isReady)
                    }
                    Button("Restart to Apply") { restart(cold: true) }
                        .disabled(coordinator.preparingKernelSU)
                }
                Link("KernelSU project and license", destination: URL(string: "https://github.com/tiann/KernelSU")!)
                    .font(.caption)
            }
            Section("Capture certificates") {
                Text("Adds a debugging proxy's root CA to the virtual device's system trust store so apps trust captured HTTPS traffic. Installing needs a rooted session: turn this on and restart with KernelSU enabled to prepare one, or boot a userdebug image with a writable system partition. Apps that pin their own certificate still fail.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Install a capture proxy certificate", isOn: $settings.captureCertificateEnabled)
                // A session booted from a userdebug image with a writable
                // system partition is rooted without KernelSU, so the warning
                // only applies while neither shape is chosen.
                if settings.captureCertificateEnabled && !settings.kernelSUEnabled && !settings.writableSystemEnabled {
                    HostNotice(message: "This needs a rooted session, and KernelSU is off. Turn on \"Boot with KernelSU\" above, then restart the emulator.")
                }
                HStack {
                    Button("Choose Certificate…") { pickCertificate() }
                        .disabled(captureControlsDisabled)
                    Spacer()
                }
                HStack {
                    TextField("Paste PEM certificate", text: $pasteText, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    Button("Use Pasted Certificate") { usePastedCertificate() }
                        .disabled(captureControlsDisabled || pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    TextField("Proxy host:port", text: $proxyText)
                        .textFieldStyle(.roundedBorder)
                    Button("Get from Proxy…") { fetchFromProxy() }
                        .disabled(captureControlsDisabled || proxyEndpoint == nil)
                }
                if !captureAvailable {
                    Text("Available while the emulator is running.").font(.caption).foregroundStyle(.secondary)
                }
                captureStatus
                HStack {
                    if captureBusy { ProgressView().controlSize(.small) }
                    Button("Remove Certificate") { removeCertificate() }
                        .disabled(captureControlsDisabled || !captureInstalled)
                    Spacer()
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
                if let volumeError { HostNotice(message: volumeError).transition(.opacity) }
            }
            Section("Camera & Microphone") {
                Toggle("Let Android apps use this Mac's microphone", isOn: $settings.hostMicrophone)
                Toggle("Let Android apps use this Mac's camera", isOn: $settings.hostCamera)
                Text("For voice and video calls. macOS asks for permission the first time an app records; the Mac's camera acts as the front camera. Takes effect after a restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Windows") {
                Picker("New windows open", selection: $settings.landscapeByDefault) {
                    Text("Landscape").tag(true)
                    Text("Portrait").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper("Default window height: \(settings.defaultWindowHeight) pt",
                        value: $settings.defaultWindowHeight, in: 500...1600, step: 50)
                Toggle("Create launchers in ~/Applications/Android Apps", isOn: $settings.launcherStubs)
                Text("Launchers let Android apps appear in Spotlight and the Dock.").font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Installed image") {
                    Text(coordinator.bootstrap.installedSystemImage(tag: settings.systemImageTag)?.packagePath ?? "none").textSelection(.enabled)
                }
                Picker("Boot with", selection: $settings.systemImageTag) {
                    ForEach(imageTagChoices, id: \.self) { tag in
                        Text(installedImageTags.contains(tag) ? tag : "\(tag) (not installed)").tag(tag)
                    }
                }
                if !installedImageTags.contains(settings.systemImageTag) {
                    Button("Download \(settings.systemImageTag) Image") { downloadSystemImage() }
                        .disabled(imageDownloadActive || runnerIsBusy)
                    Text("A userdebug image: unlike the Play image, it accepts a writable system partition. Restart the emulator to boot it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Boot with a writable system partition", isOn: $settings.writableSystemEnabled)
                Text("Boots the selected image with a writable system partition, which installing a capture certificate straight into the system trust store needs. Meaningful on a userdebug image; a Play image ignores it.")
                    .font(.caption).foregroundStyle(.secondary)
                imageDownloadStatus
                if let imageNotice {
                    Text(imageNotice).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show Logs") { NSWorkspace.shared.open(coordinator.paths.logs) }
                    Button("Show Data Folder") { NSWorkspace.shared.open(coordinator.paths.root) }
                }
                Text("Data folder: \(coordinator.paths.root.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 720)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: needsRestart)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: volumeError != nil)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: captureVerdict)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: captureError != nil)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: captureBusy)
        .task {
            // The record seeds the state, and it is the only account of what
            // the guest holds: it is read without asking the session what it
            // can do, because it has to be shown either way.
            captureState = CaptureControllerState(store: CaptureCertificateStore(root: coordinator.paths.root))
        }
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

    // MARK: System images

    /// One system image download, as the Files section shows it.
    private enum ImageDownload: Equatable {
        case idle
        case fetching(String)
        case downloading(DownloadProgress)
        case unpacking(String)
        case failed(String)
    }

    /// Tags of the installed images, newest API level only.
    private var installedImageTags: [String] {
        coordinator.bootstrap.installedSystemImages().map(\.tag)
    }

    /// Installed tags plus the two the picker must offer anyway: the selection
    /// itself (which may be waiting to be downloaded) and the userdebug image.
    private var imageTagChoices: [String] {
        var tags = installedImageTags
        for tag in [settings.systemImageTag, SDKBootstrap.userdebugTag] where !tags.contains(tag) { tags.append(tag) }
        return tags
    }

    private var imageDownloadActive: Bool {
        switch imageDownload {
        case .fetching, .downloading, .unpacking: return true
        case .idle, .failed: return false
        }
    }

    /// Downloading while the runner prepares its own components would race for
    /// the same staging directory.
    private var runnerIsBusy: Bool {
        switch coordinator.state {
        case .checking, .settingUp, .booting, .shuttingDown: return true
        case .idle, .needsSetup, .ready, .failed: return false
        }
    }

    @ViewBuilder private var imageDownloadStatus: some View {
        switch imageDownload {
        case .idle:
            EmptyView()
        case .fetching(let tag):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the \(tag) manifest…").font(.caption).foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(imageProgressLabel(progress)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .unpacking(let name):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Unpacking \(name)…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HostNotice(message: message)
        }
    }

    private func imageProgressLabel(_ progress: DownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        guard let total = progress.total else { return "Downloaded \(received)" }
        return "Downloaded \(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    /// Downloads the selected system image. The tag's own manifest supplies the
    /// archive and its size, which the confirmation states before anything is
    /// fetched; only this button starts a download.
    private func downloadSystemImage() {
        let tag = settings.systemImageTag
        guard !imageDownloadActive, !runnerIsBusy else { return }
        imageNotice = nil
        imageDownload = .fetching(tag)
        Task {
            let bootstrap = coordinator.bootstrap
            do {
                await bootstrap.setMirrors(settings.mirrors)
                let plan = try await bootstrap.makePlan(tag: tag)
                guard let image = plan.components.first(where: { $0.package.path.hasPrefix("system-images;") }) else {
                    imageDownload = .idle
                    imageNotice = "The \(tag) system image is already installed."
                    return
                }
                imageDownload = .idle
                guard confirmImageDownload(image, in: plan) else { return }
                try await bootstrap.run(plan) { phase in
                    Task { @MainActor in
                        switch phase {
                        case .fetchingManifests: imageDownload = .fetching(tag)
                        case .downloading(_, let progress): imageDownload = .downloading(progress)
                        case .extracting(let name): imageDownload = .unpacking(name)
                        case .finished: imageDownload = .idle
                        }
                    }
                }
                imageDownload = .idle
                imageNotice = "\(image.displayName) is installed. Restart the emulator to boot it."
            } catch {
                imageDownload = .failed(error.localizedDescription)
            }
        }
    }

    /// States the archive the manifest points at, and its size, before
    /// anything is fetched.
    private func confirmImageDownload(_ image: SDKComponent, in plan: BootstrapPlan) -> Bool {
        let bytes = ByteCountFormatter.string(fromByteCount: image.sizeBytes, countStyle: .file)
        var lines = ["\(image.displayName): \(bytes) from \(plan.mirror.host)."]
        let others = plan.components.filter { $0.id != image.id }
        if !others.isEmpty {
            let otherBytes = ByteCountFormatter.string(fromByteCount: plan.totalBytes - image.sizeBytes, countStyle: .file)
            lines.append("Also installs \(others.map(\.displayName).joined(separator: ", ")) (\(otherBytes)).")
        }
        lines.append("It is installed into the Mandroid data folder and used the next time the emulator starts.")
        let alert = NSAlert()
        alert.messageText = "Download the \(image.package.tagID ?? "system") system image?"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Capture certificates

    private var captureAvailable: Bool { coordinator.session?.adb != nil }

    private var captureControlsDisabled: Bool { !captureAvailable || captureBusy }

    private var captureInstalled: Bool {
        if case .installed = captureState { return true }
        return false
    }

    /// The typed proxy address, or nil while the field is empty or incomplete.
    private var proxyEndpoint: HTTPProxyEndpoint? {
        let text = proxyText.trimmingCharacters(in: .whitespaces)
        guard let colon = text.lastIndex(of: ":"), colon != text.startIndex else { return nil }
        let portText = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let port = Int(portText) else { return nil }
        return try? HTTPProxyEndpoint(host: String(text[..<colon]), port: port)
    }

    /// The controller for one action, built for the endpoint the action started
    /// with so no endpoint travels through the controller itself and nothing
    /// re-reads the field mid-install. The checker is built once here rather
    /// than per evaluation. Actions that install without an endpoint never
    /// reach the provider, which is why the endpoint-less one only says so.
    /// The injector is chosen per action rather than once for the section: the
    /// session's shape for an install, the record's backend for a removal.
    private func captureController(for endpoint: HTTPProxyEndpoint?,
                                   injector: any CertificateInjecting) -> CaptureCertificateController {
        let store = CaptureCertificateStore(root: coordinator.paths.root)
        guard let endpoint else {
            return CaptureCertificateController(
                store: store, injector: injector,
                verdict: { _ in .unreachable("No proxy address was entered, so no pre-flight check ran.") })
        }
        let checker = CertificateChainChecker(probe: ProxyProbe(endpoint: endpoint))
        return CaptureCertificateController(
            store: store, injector: injector,
            verdict: { await checker.evaluate(certificate: $0) })
    }

    /// What the running session's shell offers, for one action. A session
    /// booted with a writable system partition starts with a plain shell —
    /// `adb root` is what makes its shell root — so that shape is asked for
    /// root first, the way the runner's post-boot rebuild does; a KernelSU
    /// session answers `su` without one.
    private func sessionCapabilities(_ session: EmulatorSession) async -> GuestSessionCapabilities {
        if session.options.writableSystem {
            return await WritableSystemInjector().activateRoot(adb: session.adb)
        }
        return await GuestSessionCapabilities.detect(adb: session.adb)
    }

    /// Shown when an action meets a session that offers no root at all.
    private static let needsRootedSession =
        "This needs a rooted session. Turn on \"Boot with KernelSU\" above and restart, or start a session from a userdebug image with a writable system partition."

    /// Why a recorded certificate cannot be taken out here: the record names
    /// the artifact that exists, and this session cannot run the procedure that
    /// removes it.
    private static func removalNeeds(backend: CaptureBackend) -> String {
        switch backend {
        case .kernelSUModule:
            return "This certificate was installed as a KernelSU module, and only a KernelSU session can take it out. Turn on \"Boot with KernelSU\" above, turn off the writable system, and restart the emulator."
        case .writableSystem:
            return "This certificate was written straight into the system trust store, and only a session whose shell is root can take it out. Turn on \"Boot with a writable system partition\" below, boot a userdebug image, and restart the emulator."
        }
    }

    /// Runs one capture action with the section busy and reports its failure in
    /// the notice line.
    private func captureAction(_ action: @escaping @MainActor () async throws -> Void) {
        guard !captureBusy else { return }
        captureBusy = true
        captureError = nil
        Task {
            defer { captureBusy = false }
            do { try await action() } catch { captureError = error.localizedDescription }
        }
    }

    private func pickCertificate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pem", "crt", "cer", "der"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let endpoint = proxyEndpoint
        captureAction { await install(try await CertificateImporter.certificate(fromFile: url), endpoint: endpoint) }
    }

    private func usePastedCertificate() {
        let text = pasteText, endpoint = proxyEndpoint
        captureAction { await install(try await CertificateImporter.certificate(fromPastedText: text), endpoint: endpoint) }
    }

    private func fetchFromProxy() {
        guard let endpoint = proxyEndpoint else { return }
        captureAction {
            switch await CertificateAuthorityResolver(probe: ProxyProbe(endpoint: endpoint)).certificate() {
            case .found(let certificate, let via):
                await install(certificate, endpoint: endpoint, origin: "Fetched from \(via).")
            case .failed(let reasons):
                captureError = reasons.joined(separator: "\n")
            }
        }
    }

    /// Confirms a resolved certificate and installs it. With an endpoint the
    /// pre-flight verdict runs inside the controller and anything it refuses
    /// lands in the status line as that verdict; without one the proxy is never
    /// contacted, which the user accepts before the install proceeds.
    private func install(_ certificate: CaptureCertificate, endpoint: HTTPProxyEndpoint?, origin: String? = nil) async {
        guard let session = coordinator.session else {
            captureError = "Start the emulator before installing a certificate."
            return
        }
        // The session is asked before the certificate is confirmed, so nothing
        // is promised that this session cannot do.
        let capabilities = await sessionCapabilities(session)
        guard let injector = CertificateInjectorFactory.injector(for: capabilities) else {
            captureError = Self.needsRootedSession
            return
        }
        let adb = session.adb
        guard confirmInstall(certificate, origin: origin) else { return }
        if endpoint == nil, !confirmUnverified() { return }
        captureVerdict = nil
        do {
            let controller = captureController(for: endpoint, injector: injector)
            let installation: CaptureInstallation
            if endpoint == nil {
                installation = try await controller.installUnverified(certificate, adb: adb)
            } else {
                installation = try await controller.install(certificate, adb: adb)
            }
            captureState = .installed(installation)
        } catch CapturePreflightError.verdict(let verdict) {
            captureVerdict = verdict
        } catch {
            captureError = error.localizedDescription
        }
    }

    /// Shows the subject and validity the certificate resolved to before
    /// anything is installed, the way removing one asks for confirmation.
    private func confirmInstall(_ certificate: CaptureCertificate, origin: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install \(certificate.subject)?"
        var lines = ["Valid from \(certificate.notBefore.formatted(date: .abbreviated, time: .omitted))"
                     + " to \(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))."]
        if let origin { lines.append(origin) }
        lines.append("It is added to the system trust store of the running virtual device as \(certificate.storeFileName).")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The separate confirmation for an install with no endpoint to check
    /// against: the proxy was never contacted, so nothing was verified.
    private func confirmUnverified() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install without checking the proxy?"
        alert.informativeText = "No proxy address was entered, so the proxy was not contacted and this certificate is not verified to be the one the proxy signs with. It is added to the system trust store anyway."
        alert.addButton(withTitle: "Install Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func removeCertificate() {
        captureAction {
            guard let session = coordinator.session else {
                captureError = "Start the emulator before removing a certificate."
                return
            }
            let installation: CaptureInstallation?
            do {
                installation = try CaptureCertificateStore(root: coordinator.paths.root).load()
            } catch {
                captureError = error.localizedDescription
                return
            }
            guard let installation else {
                captureError = "No certificate is recorded for this virtual device."
                return
            }
            // The record decides which procedure takes the certificate out —
            // the artifact it names is the one that exists — and this session
            // only decides whether it can run that procedure. Running the other
            // shape's would leave the artifact behind while reporting success.
            let plan = CertificateInjectorFactory.remover(for: installation.backend,
                                                          capabilities: await sessionCapabilities(session))
            switch plan {
            case .refused(let backend):
                captureError = Self.removalNeeds(backend: backend)
            case .injector(let injector):
                try await captureController(for: nil, injector: injector).remove(adb: session.adb)
                captureState = .idle
                captureVerdict = nil
            }
        }
    }

    /// The installed subject and expiry, the pre-flight verdict, or why neither
    /// is available.
    @ViewBuilder private var captureStatus: some View {
        if case .installed(let installation) = captureState {
            Label("Installed: \(installation.subject), expires \(installation.notAfter.formatted(date: .abbreviated, time: .omitted))",
                  systemImage: "checkmark.circle")
        } else if case .unavailable(let reason) = captureState {
            HostNotice(message: reason)
        } else {
            Text("No certificate is installed.").font(.caption).foregroundStyle(.secondary)
        }
        if let captureVerdict {
            HostNotice(message: CapturePreflightError.verdict(captureVerdict).localizedDescription)
        }
        if let captureError {
            HostNotice(message: captureError)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    init(coordinator: RunnerCoordinator, windows: WindowManager) {
        let host = NSHostingController(rootView: SettingsView(coordinator: coordinator, windows: windows))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: 480, height: 420)
        window.setContentSize(NSSize(width: 560, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError() }
}
