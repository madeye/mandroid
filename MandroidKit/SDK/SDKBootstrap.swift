import Foundation

/// One downloadable SDK component and where it lands on disk.
public struct SDKComponent: Sendable, Identifiable, Hashable {
    public var id: String { package.path }
    public var package: RepositoryManifest.Package
    public var archive: RepositoryManifest.Archive
    /// Directory that will contain the package content (e.g. `<sdk>/emulator`).
    public var installDirectory: URL
    public var displayName: String { package.displayName }
    public var sizeBytes: Int64 { archive.size }
}

/// What still has to be downloaded to reach a bootable state.
public struct BootstrapPlan: Sendable {
    public var components: [SDKComponent]
    public var licenses: [RepositoryManifest.License]
    public var systemImagePath: String
    /// Mirror the manifests came from; archive URLs point at it.
    public var mirror: DownloadMirror = .google
    public var totalBytes: Int64 { components.reduce(0) { $0 + $1.sizeBytes } }
    public var isEmpty: Bool { components.isEmpty }
}

public enum BootstrapPhase: Sendable, Equatable {
    case fetchingManifests
    case downloading(component: String, progress: DownloadProgress)
    case extracting(component: String)
    case finished
}

/// Downloads and installs emulator, platform-tools and a system image into
/// the isolated SDK root, without Java or sdkmanager.
public actor SDKBootstrap {
    public let paths: SDKPaths
    private let downloader: Downloader
    private let session: URLSession
    /// Download hosts to try, most preferred first.
    public private(set) var mirrors: [DownloadMirror] = DownloadMirror.order(for: .auto)

    public static let defaultTag = "google_apis_playstore"
    /// Tag of Google's userdebug builds. Unlike the Play images they accept a
    /// writable system partition, which a capture certificate needs when it
    /// goes into the system trust store as root.
    public static let userdebugTag = "google_apis"
    /// Apple silicon only: arm64 system images under HVF.
    public static let defaultABI = "arm64-v8a"

    public init(paths: SDKPaths, session: URLSession = .shared) {
        self.paths = paths
        self.session = session
        self.downloader = Downloader(session: session)
    }

    public func setMirrors(_ mirrors: [DownloadMirror]) {
        if !mirrors.isEmpty { self.mirrors = mirrors }
    }

    // MARK: Installed state

    /// Reads `Pkg.Revision` from a component's `source.properties`.
    public nonisolated func installedRevision(at directory: URL) -> RepositoryManifest.Revision? {
        let file = directory.appendingPathComponent("source.properties")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "Pkg.Revision" {
                let nums = parts[1].split(separator: ".").compactMap { Int($0) }
                guard let major = nums.first else { return nil }
                return .init(major: major, minor: nums.count > 1 ? nums[1] : 0, micro: nums.count > 2 ? nums[2] : 0)
            }
        }
        return nil
    }

    /// The system image directory currently installed, if any
    /// (`<sdk>/system-images/<api>/<tag>/<abi>` containing `system.img`).
    public nonisolated func installedSystemImage() -> (packagePath: String, directory: URL)? {
        systemImageDirectories()
            .sorted { $0.apiLevel > $1.apiLevel }
            .first.map { ($0.packagePath, $0.directory) }
    }

    /// Every installed image at the highest API level present, one entry per
    /// tag. Tags stay apart: `google_apis` and `google_apis_playstore` are
    /// different images at the same level.
    public nonisolated func installedSystemImages() -> [(packagePath: String, directory: URL, tag: String)] {
        let images = systemImageDirectories()
        guard let level = images.map(\.apiLevel).max() else { return [] }
        return images
            .filter { $0.apiLevel == level }
            .sorted { $0.packagePath < $1.packagePath }
            .map { ($0.packagePath, $0.directory, $0.tag) }
    }

    /// The installed image for `tag`, preferring the highest API level that has
    /// one. Matching is by tag, so a `google_apis_playstore` image is never
    /// returned for `google_apis`.
    public nonisolated func installedSystemImage(tag: String) -> (packagePath: String, directory: URL)? {
        systemImageDirectories()
            .filter { $0.tag == tag }
            .sorted { $0.apiLevel > $1.apiLevel }
            .first.map { ($0.packagePath, $0.directory) }
    }

    /// The first of `packagePaths` whose tag is `tag`, or nil when none
    /// matches. Paths are shaped `system-images;<api>;<tag>;<abi>`.
    public static func image(matching tag: String, among packagePaths: [String]) -> String? {
        packagePaths.first { self.tag(of: $0) == tag }
    }

    /// The tag component of a `system-images;<api>;<tag>;<abi>` path.
    private static func tag(of packagePath: String) -> String? {
        let parts = packagePath.split(separator: ";")
        guard parts.count == 4, parts[0] == "system-images" else { return nil }
        return String(parts[2])
    }

    /// Every `<sdk>/system-images/<api>/<tag>/<abi>` holding a `system.img`,
    /// with the API level as a sort key.
    private nonisolated func systemImageDirectories() -> [(packagePath: String, directory: URL, tag: String, apiLevel: Double)] {
        let fm = FileManager.default
        guard let apis = try? fm.contentsOfDirectory(atPath: paths.systemImagesDir.path) else { return [] }
        var found: [(packagePath: String, directory: URL, tag: String, apiLevel: Double)] = []
        for api in apis {
            let apiDir = paths.systemImagesDir.appendingPathComponent(api)
            for tag in (try? fm.contentsOfDirectory(atPath: apiDir.path)) ?? [] {
                let tagDir = apiDir.appendingPathComponent(tag)
                for abi in (try? fm.contentsOfDirectory(atPath: tagDir.path)) ?? [] {
                    let dir = tagDir.appendingPathComponent(abi)
                    if fm.fileExists(atPath: dir.appendingPathComponent("system.img").path) {
                        let level = Double(api.replacingOccurrences(of: "android-", with: "")) ?? 0
                        found.append(("system-images;\(api);\(tag);\(abi)", dir, tag, level))
                    }
                }
            }
        }
        return found
    }

    public nonisolated var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: paths.emulatorBinary.path)
            && FileManager.default.isExecutableFile(atPath: paths.adbBinary.path)
            && installedSystemImage() != nil
    }

    // MARK: Planning

    /// Fetches both manifests from the first reachable mirror.
    public func fetchManifests(tag: String = SDKBootstrap.defaultTag) async throws
        -> (repository: RepositoryManifest, systemImages: RepositoryManifest, mirror: DownloadMirror) {
        var lastError: Error?
        for mirror in mirrors {
            do {
                async let repo = fetchManifest(mirror.repositoryManifestURL)
                async let img = fetchManifest(mirror.systemImageManifestURL(tag: tag))
                let result = try await (repo, img, mirror)
                Log.sdk.info("using download mirror \(mirror.id)")
                return result
            } catch {
                try Task.checkCancellation()
                Log.sdk.error("manifests from \(mirror.host) failed: \(error.localizedDescription)")
                Log.file("mirror \(mirror.id) unreachable: \(error.localizedDescription)", paths: paths)
                lastError = error
            }
        }
        throw lastError ?? MandroidKitError.manifest("no download mirror reachable")
    }

    private func fetchManifest(_ url: URL) async throws -> RepositoryManifest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MandroidKitError.manifest("could not fetch \(url.lastPathComponent)")
        }
        // Keep a copy for diagnostics.
        try? data.write(to: paths.cache.appendingPathComponent(url.lastPathComponent))
        return try RepositoryManifest.parse(data: data, baseURL: url)
    }

    /// Builds the plan of missing components. `preferredAPI` (e.g. "36.1")
    /// selects a system image; otherwise the newest stable one is used.
    public func makePlan(tag: String = SDKBootstrap.defaultTag,
                         abi: String = SDKBootstrap.defaultABI,
                         preferredAPI: String? = nil) async throws -> BootstrapPlan {
        let (repo, imgs, mirror) = try await fetchManifests(tag: tag)
        var plan = try Self.plan(repository: repo, systemImages: imgs, paths: paths, tag: tag, abi: abi,
                                 preferredAPI: preferredAPI, installedRevision: installedRevision(at:))
        plan.mirror = mirror
        return plan
    }

    /// Pure planning function (unit-testable).
    public static func plan(repository repo: RepositoryManifest,
                            systemImages imgs: RepositoryManifest,
                            paths: SDKPaths,
                            tag: String,
                            abi: String,
                            preferredAPI: String?,
                            installedRevision: (URL) -> RepositoryManifest.Revision?) throws -> BootstrapPlan {
        guard let (emuPkg, emuArchive) = repo.package(path: "emulator") else {
            throw MandroidKitError.manifest("no stable emulator for this Mac in the repository")
        }
        guard let (ptPkg, ptArchive) = repo.package(path: "platform-tools") else {
            throw MandroidKitError.manifest("no platform-tools in the repository")
        }
        let images = imgs.systemImages(tag: tag, abi: abi)
        let candidates = images.filter { pkg, _ in
            // Respect the image's minimum emulator revision.
            if let dep = pkg.dependencies.first(where: { $0.path == "emulator" }), let min = dep.minRevision {
                return emuPkg.revision >= min
            }
            return true
        }
        let chosen: (RepositoryManifest.Package, RepositoryManifest.Archive)?
        if let preferredAPI {
            chosen = candidates.first { $0.0.apiLevel == preferredAPI } ?? candidates.first
        } else {
            chosen = candidates.first
        }
        guard let (imgPkg, imgArchive) = chosen else {
            throw MandroidKitError.manifest("no \(tag) \(abi) system image available")
        }

        var components: [SDKComponent] = []
        func need(_ pkg: RepositoryManifest.Package, _ archive: RepositoryManifest.Archive, _ dir: URL) {
            if let installed = installedRevision(dir), installed >= pkg.revision { return }
            components.append(SDKComponent(package: pkg, archive: archive, installDirectory: dir))
        }
        need(ptPkg, ptArchive, paths.platformToolsDir)
        need(emuPkg, emuArchive, paths.emulatorDir)
        need(imgPkg, imgArchive, paths.directory(forPackagePath: imgPkg.path))

        var licenses: [RepositoryManifest.License] = []
        for (pkg, manifest) in [(ptPkg, repo), (emuPkg, repo), (imgPkg, imgs)] {
            if let ref = pkg.licenseRef, let lic = manifest.licenses[ref], !licenses.contains(lic) {
                licenses.append(lic)
            }
        }
        return BootstrapPlan(components: components, licenses: licenses, systemImagePath: imgPkg.path)
    }

    // MARK: Execution

    /// True while `run` is installing. A second install is refused rather than
    /// queued: both would write the same archive and `.part` files under
    /// `downloads/`, so the later one would fail only after downloading.
    private var installing = false

    public func run(_ plan: BootstrapPlan, progress: @escaping @Sendable (BootstrapPhase) -> Void) async throws {
        guard !installing else {
            throw MandroidKitError.download("another install is already in progress; try again when it finishes")
        }
        installing = true
        defer { installing = false }
        try paths.createDirectories()
        try writeLicenses(plan.licenses)
        for component in plan.components {
            try Task.checkCancellation()
            let name = component.displayName
            let zip = paths.downloads.appendingPathComponent(component.archive.url.lastPathComponent)
            try await downloadWithFallback(component.archive.url, from: plan.mirror, to: zip,
                                           expectedSize: component.archive.size,
                                           sha1: component.archive.sha1) { p in
                progress(.downloading(component: name, progress: p))
            }
            progress(.extracting(component: name))
            try await install(zip: zip, into: component.installDirectory)
            try? FileManager.default.removeItem(at: zip)
        }
        progress(.finished)
    }

    /// Downloads from the plan's mirror; if that fails (a mirror lagging behind
    /// the manifest, or an unreachable host) the same path is tried on the
    /// other mirrors before giving up.
    private func downloadWithFallback(_ url: URL, from mirror: DownloadMirror, to destination: URL,
                                      expectedSize: Int64?, sha1: String?,
                                      progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        var candidates = [url]
        for other in mirrors where other != mirror {
            if let alt = mirror.rewrite(url, to: other) { candidates.append(alt) }
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                try await downloader.download(candidate, to: destination, expectedSize: expectedSize, sha1: sha1, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Log.sdk.error("download from \(candidate.host ?? "?") failed: \(error.localizedDescription)")
                Log.file("download \(candidate.absoluteString) failed: \(error.localizedDescription)", paths: paths)
                lastError = error
            }
        }
        throw lastError ?? MandroidKitError.download("no mirror could serve \(url.lastPathComponent)")
    }

    /// Extracts into a staging directory, then moves the zip's single
    /// top-level folder to `destination` (replacing any previous install).
    private func install(zip: URL, into destination: URL) async throws {
        let fm = FileManager.default
        let staging = paths.downloads.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try await Unarchiver.extract(zip: zip, into: staging)
        let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        let source: URL
        if entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            source = entries[0]
        } else {
            source = staging
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: source, to: destination)
    }

    private func writeLicenses(_ licenses: [RepositoryManifest.License]) throws {
        try FileManager.default.createDirectory(at: paths.licenses, withIntermediateDirectories: true)
        for lic in licenses {
            let file = paths.licenses.appendingPathComponent(lic.id)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if !existing.contains(lic.hash) {
                try (existing + (existing.isEmpty ? "" : "\n") + lic.hash + "\n").write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
