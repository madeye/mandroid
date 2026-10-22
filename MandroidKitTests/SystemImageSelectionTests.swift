import Foundation
import Testing
@testable import MandroidKit

/// A session's system image is chosen by tag: `google_apis` and
/// `google_apis_playstore` are different images at the same API level, and the
/// userdebug one is what a writable system partition needs.
@Suite struct SystemImageSelectionTests {
    /// Two tags at the newest installed API level plus one older image whose
    /// tag is skipped because a newer level exists.
    private func makeInstalledImages() throws -> (paths: SDKPaths, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = SDKPaths(root: root)
        for (api, tag) in [("android-33", "google_apis_playstore"), ("android-33", "google_apis"),
                           ("android-30", "google_apis")] {
            let directory = paths.systemImagesDir.appendingPathComponent("\(api)/\(tag)/arm64-v8a")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("system.img".utf8).write(to: directory.appendingPathComponent("system.img"))
        }
        return (paths, root)
    }

    @Test func installedImagesReportEveryTag() throws {
        let (paths, root) = try makeInstalledImages()
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = SDKBootstrap(paths: paths)
        let images = bootstrap.installedSystemImages().map(\.packagePath).sorted()
        #expect(images == ["system-images;android-33;google_apis;arm64-v8a",
                           "system-images;android-33;google_apis_playstore;arm64-v8a"])
    }

    @Test func imageChoicePrefersConfiguredTag() throws {
        let (paths, root) = try makeInstalledImages()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = SDKBootstrap(paths: paths).installedSystemImages().map(\.packagePath)
        let chosen = SDKBootstrap.image(matching: "google_apis", among: installed)
        #expect(chosen?.contains(";google_apis;") == true)
        #expect(chosen == "system-images;android-33;google_apis;arm64-v8a")
        // A tag that is not installed is never substituted by a related one.
        #expect(SDKBootstrap.image(matching: "google_apis",
                                   among: ["system-images;android-33;google_apis_playstore;arm64-v8a"]) == nil)
        #expect(SDKBootstrap.image(matching: "aosp_atd", among: installed) == nil)
    }

    @Test func tagLookupTakesTheNewestLevelOfThatTag() throws {
        let (paths, root) = try makeInstalledImages()
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = SDKBootstrap(paths: paths)
        #expect(bootstrap.installedSystemImage(tag: "google_apis")?.packagePath
                == "system-images;android-33;google_apis;arm64-v8a")
        #expect(bootstrap.installedSystemImage(tag: "google_apis_playstore")?.packagePath
                == "system-images;android-33;google_apis_playstore;arm64-v8a")
        #expect(bootstrap.installedSystemImage(tag: "aosp_atd") == nil)
        // The shipped lookup is untouched: the highest API level wins, whatever
        // its tag, which is what the Play-only installs relied on.
        #expect(bootstrap.installedSystemImage()?.packagePath.contains(";android-33;") == true)
    }

    @Test func systemImageTagPersistsAndStaysIndependent() throws {
        let suite = "system-image-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stock = RunnerSettings()
        #expect(stock.systemImageTag == SDKBootstrap.defaultTag)
        var chosen = stock
        chosen.systemImageTag = SDKBootstrap.userdebugTag
        chosen.save(to: defaults)
        #expect(RunnerSettings.load(from: defaults).systemImageTag == SDKBootstrap.userdebugTag)
        #expect(chosen.requiresRestart(comparedTo: stock))
        stock.save(to: defaults)
        #expect(RunnerSettings.load(from: defaults).systemImageTag == SDKBootstrap.defaultTag)
        // Choosing an image never turns on the writable system partition by
        // itself; that stays a separate choice.
        var options = EmulatorLaunchOptions(avdName: "runner", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
        chosen.apply(to: &options)
        #expect(!options.writableSystem)
    }

    /// The download entry point resolves the tag to its own manifest and
    /// reports that manifest's archive size; no archive is fetched here.
    @Test func googleApisPlanReportsArchiveSizeFromManifest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SystemImageManifestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = SDKPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let bootstrap = SDKBootstrap(paths: paths, session: session)
        await bootstrap.setMirrors([.google])
        let plan = try await bootstrap.makePlan(tag: SDKBootstrap.userdebugTag)
        let image = try #require(plan.components.first { $0.package.path.hasPrefix("system-images;") })
        #expect(image.package.tagID == SDKBootstrap.userdebugTag)
        #expect(image.sizeBytes == 1_234_567_890)
        #expect(plan.systemImagePath == "system-images;android-33;google_apis;arm64-v8a")
        #expect(image.installDirectory.path.hasSuffix("sdk/system-images/android-33/google_apis/arm64-v8a"))
    }
}

/// Installs write fixed archive paths under the SDK's `downloads/` directory,
/// so two of them must never overlap.
@Suite struct SDKInstallExclusionTests {
    /// A small archive in the shape the install path expects, built with the
    /// same tool the extractor uses.
    private func makeArchive(in root: URL) async throws -> Data {
        let source = root.appendingPathComponent("archive-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("system image".utf8).write(to: source.appendingPathComponent("system.img"))
        let zip = root.appendingPathComponent("system-image.zip")
        let result = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                              arguments: ["-c", "-k", source.path, zip.path])
        guard result.status == 0 else {
            throw MandroidKitError.unarchive("ditto -c -k exited \(result.status)")
        }
        return try Data(contentsOf: zip)
    }

    /// The download is stubbed by the archive's `.part` file, which the
    /// downloader accepts as the finished archive, so nothing here touches the
    /// network; the gate then holds that first install in flight.
    ///
    /// A second request is refused rather than queued or interleaved. The
    /// second plan has no components and only writes one license file, so a run
    /// that is wrongly allowed finishes immediately and leaves that file behind
    /// instead of queueing behind the held download.
    @Test func secondInstallIsRefusedWhileOneRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = SDKPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = try await makeArchive(in: root)
        let part = paths.downloads.appendingPathComponent("system-image.zip").appendingPathExtension("part")
        try archive.write(to: part)
        let component = SDKComponent(
            package: .init(path: "system-images;android-33;google_apis;arm64-v8a", revision: .init(major: 17),
                           displayName: "Google APIs ARM 64 v8a System Image", channel: "channel-0",
                           licenseRef: nil, archives: [], dependencies: [], apiLevel: "33",
                           tagID: SDKBootstrap.userdebugTag, abi: "arm64-v8a"),
            archive: .init(hostOS: nil, hostArch: nil,
                           url: try #require(URL(string: "https://stub.invalid/system-image.zip")),
                           size: Int64(archive.count), sha1: SHA1.hex(of: archive)),
            installDirectory: root.appendingPathComponent("installed", isDirectory: true))
        let plan = BootstrapPlan(components: [component], licenses: [], systemImagePath: component.package.path)

        let marker = RepositoryManifest.License(id: "second-install", text: "second install")
        let second = BootstrapPlan(components: [], licenses: [marker], systemImagePath: "none")

        let bootstrap = SDKBootstrap(paths: paths)
        let gate = InstallGate()
        let running = Task {
            try await bootstrap.run(plan) { phase in
                if case .downloading = phase { gate.hold() }
            }
        }
        gate.waitUntilHolding()
        await #expect(throws: MandroidKitError.download("another install is already in progress; try again when it finishes")) {
            try await bootstrap.run(second) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: paths.licenses.appendingPathComponent(marker.id).path))
        gate.open()
        try await running.value
        #expect(FileManager.default.fileExists(
            atPath: component.installDirectory.appendingPathComponent("system.img").path))

        // The guard is released with the install that held it.
        try archive.write(to: part)
        try await bootstrap.run(plan) { _ in }
    }
}

/// Holds the first download of a run until the test releases it, so a second
/// install can be attempted while that run is in flight.
private final class InstallGate: @unchecked Sendable {
    private let holding = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var holdsFirst = true

    /// Blocks the first download; later progress reports pass through.
    func hold() {
        lock.lock()
        let first = holdsFirst
        holdsFirst = false
        lock.unlock()
        guard first else { return }
        holding.signal()
        release.wait()
    }

    /// Returns once a download is being held.
    func waitUntilHolding() { holding.wait() }

    func open() { release.signal() }
}

/// Serves the repository fixture and a stub `google_apis` system image
/// manifest. Any other URL — including the Play image's manifest — is a 404,
/// so a download that resolves the wrong tag cannot pass.
private final class SystemImageManifestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: Data?
        switch url.path {
        case "/android/repository/repository2-3.xml": body = try? Fixtures.data("repository2-3.xml")
        case "/android/repository/sys-img/google_apis/sys-img2-3.xml": body = Self.googleApisManifest
        default: body = nil
        }
        send(url: url, status: body == nil ? 404 : 200, body: body ?? Data())
    }

    override func stopLoading() {}

    private func send(url: URL, status: Int, body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "\(body.count)"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    static let googleApisManifest = Data("""
        <?xml version='1.0' encoding='utf-8'?>
        <sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <license id="android-sdk-arm-dbt-license" type="text">Stub license for the test manifest.</license>
          <remotePackage path="system-images;android-33;google_apis;arm64-v8a">
            <type-details xsi:type="sys-img:sysImgDetailsType">
              <api-level>33</api-level>
              <tag>
                <id>google_apis</id>
                <display>Google APIs</display>
              </tag>
              <abi>arm64-v8a</abi>
            </type-details>
            <revision>
              <major>17</major>
            </revision>
            <display-name>Google APIs ARM 64 v8a System Image</display-name>
            <uses-license ref="android-sdk-arm-dbt-license"/>
            <channelRef ref="channel-0"/>
            <archives>
              <archive>
                <complete>
                  <size>1234567890</size>
                  <checksum type="sha1">0000000000000000000000000000000000000000</checksum>
                  <url>arm64-v8a-33_r17.zip</url>
                </complete>
              </archive>
            </archives>
          </remotePackage>
        </sys-img:sdk-sys-img>
        """.utf8)
}
