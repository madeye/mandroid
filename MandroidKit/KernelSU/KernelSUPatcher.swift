import CryptoKit
import Foundation

/// Pinned, experimental AVD support. Stock SDK files are only ever read.
public struct KernelSUPatcher: Sendable {
    public static let version = "3.3.0"
    public static let kernelVersion = "6.12.38-android16-5-gbb9513914902-ab13996879-4k"
    public static let managerPackage = "me.weishu.kernelsu"
    let root: URL

    struct Asset: Sendable {
        let name: String
        let sha256: String
        var url: URL { URL(string: "https://github.com/tiann/KernelSU/releases/download/v3.3.0/\(name)")! }
    }
    static let assets: [Asset] = [
        .init(name: "ksud-aarch64-apple-darwin", sha256: "40ca97a2fb61284129909abac5325dcae790736d9b88901f4f31cc7ec6d9a705"),
        .init(name: "ksuinit-aarch64", sha256: "b49fff3252cdcd14bf80472becbd96c4f17028a632b364e8d455d335b94f1345"),
        .init(name: "lkm-aarch64-android16-6.12_kernelsu.ko", sha256: "877286f81d500c4ec546c96e9718c186b7379573c97ba5d5a35dd9a91465d076"),
        .init(name: "KernelSU_v3.3.0_32601-release.apk", sha256: "c197060ecb89702e7d54a4c95e29cf5e8d97369bbbb436979ab7fd6bcde7b077"),
    ]

    public struct Prepared: Sendable {
        public let ramdisk: URL
        public let manager: URL
        let guestTool: URL
    }

    struct Manifest: Codable, Equatable {
        let version: String
        let kernelHash: String
        let stockRamdiskHash: String
        let patchedHash: String
        let guestToolHash: String
        let allowShell: Bool
    }

    /// A patch built with shell root serves a different purpose from a plain
    /// one, so the two never share a cache directory.
    public static func cacheDirectoryName(version: String, kernelHash: String, stockHash: String, allowShell: Bool) -> String {
        let base = "v\(version)-\(kernelHash)-\(stockHash)"
        return allowShell ? base + "-shell" : base
    }

    /// Whether a prepared ramdisk came from a patch built with shell root. The
    /// cache directory name is where that choice is recorded on disk, so a
    /// running session's ramdisk answers for the patch it was booted from.
    public static func allowsShell(ramdisk: URL?) -> Bool {
        guard let ramdisk else { return false }
        return ramdisk.deletingLastPathComponent().lastPathComponent.hasSuffix("-shell")
    }

    public init(paths: SDKPaths) {
        root = paths.root.appendingPathComponent("boot-patches/kernelsu", isDirectory: true)
    }

    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func requireSupportedKernel(_ bytes: Data) throws {
        // Match the whole version, including 4K page size, rather than guessing
        // compatibility from the SDK API number or the kernel's major version.
        let marker = Data("Linux version \(kernelVersion) ".utf8)
        guard bytes.range(of: marker) != nil else {
            throw Failure("This image's kernel is unsupported. KernelSU currently supports the Android 36.1 ARM64 image with kernel \(kernelVersion). Turn KernelSU off to boot the stock image.")
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "KernelSU: \(message)" }
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> SubprocessResult {
        try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
            group.addTask { try await Subprocess.run(executable, arguments: arguments) }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw Failure("The image tool timed out. Retry preparing the image.")
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            guard result.status == 0 else {
                throw Failure("Image tool failed (\(result.status)): \(result.stderrText.suffix(1000))")
            }
            return result
        }
    }

    /// The coordinator coalesces concurrent callers into one cancellable task.
    /// `allowShell` grants the ADB shell root on the patched ramdisk, which the
    /// certificate installer needs to write the guest trust store.
    public func prepare(imageDirectory: URL, allowShell: Bool,
                        progress: @Sendable (String) async -> Void) async throws -> Prepared {
        let fm = FileManager.default
        let kernel = imageDirectory.appendingPathComponent("kernel-ranchu")
        let stock = imageDirectory.appendingPathComponent("ramdisk.img")
        await progress("Checking image compatibility…")
        let expanded = try await Self.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", kernel.path])
        try Self.requireSupportedKernel(expanded.stdout)
        let kernelHash = try Self.hash(kernel), stockHash = try Self.hash(stock)
        let assetsDirectory = root.appendingPathComponent("assets-v\(Self.version)", isDirectory: true)
        try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        for asset in Self.assets {
            try Task.checkCancellation()
            let destination = assetsDirectory.appendingPathComponent(asset.name)
            if (try? Self.hash(destination)) == asset.sha256 { continue }
            await progress("Downloading \(asset.name)…")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (temporary, response) = try await session.download(from: asset.url)
            defer { try? fm.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw Failure("Could not download \(asset.name) from GitHub. Check the connection and retry.")
            }
            let actual = try Self.hash(temporary)
            guard actual == asset.sha256 else {
                throw MandroidKitError.checksumMismatch(expected: asset.sha256, actual: actual, file: asset.name)
            }
            try Task.checkCancellation()
            // Only verified bytes replace a cached download.
            try Data(contentsOf: temporary).write(to: destination, options: .atomic)
        }
        let final = root.appendingPathComponent(Self.cacheDirectoryName(version: Self.version, kernelHash: kernelHash,
                                                                       stockHash: stockHash, allowShell: allowShell),
                                                isDirectory: true)
        let manager = assetsDirectory.appendingPathComponent(Self.assets[3].name)
        if Self.validCache(at: final, kernelHash: kernelHash, stockHash: stockHash, allowShell: allowShell) {
            return Prepared(ramdisk: final.appendingPathComponent("ramdisk.img"), manager: manager,
                            guestTool: final.appendingPathComponent("ksud-android"))
        }
        await progress("Patching a copy of the ramdisk…")
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let input = staging.appendingPathComponent("stock.img")
        try fm.copyItem(at: stock, to: input)
        let tool = assetsDirectory.appendingPathComponent(Self.assets[0].name)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        var patchArguments = ["boot-patch", "--ramdisk", "-b", input.path,
            "-m", assetsDirectory.appendingPathComponent(Self.assets[2].name).path,
            "-i", assetsDirectory.appendingPathComponent(Self.assets[1].name).path,
            "--kmi", "android16-6.12", "-o", staging.path, "--out-name", "ramdisk.img"]
        if allowShell { patchArguments.append("--allow-shell") }
        _ = try await Self.run(tool, patchArguments)
        let guest = try await Self.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", manager.path, "lib/arm64-v8a/libksud.so"])
        guard !guest.stdout.isEmpty else { throw Failure("The Manager APK has no ARM64 helper.") }
        let guestTool = staging.appendingPathComponent("ksud-android")
        try guest.stdout.write(to: guestTool)
        let outputHash = try Self.hash(staging.appendingPathComponent("ramdisk.img"))
        guard outputHash != stockHash, try Self.hash(stock) == stockHash, try Self.hash(kernel) == kernelHash else {
            throw Failure("The system image changed while patching. Retry preparing the image.")
        }
        let manifest = Manifest(version: Self.version, kernelHash: kernelHash, stockRamdiskHash: stockHash,
                                patchedHash: outputHash, guestToolHash: try Self.hash(guestTool), allowShell: allowShell)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.removeItem(at: input)
        try Task.checkCancellation()
        // A directory is published only after successful patching and hashing.
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staging, to: final)
        return Prepared(ramdisk: final.appendingPathComponent("ramdisk.img"), manager: manager,
                        guestTool: final.appendingPathComponent("ksud-android"))
    }

    static func validCache(at directory: URL, kernelHash: String, stockHash: String, allowShell: Bool) -> Bool {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
              manifest.version == version, manifest.kernelHash == kernelHash, manifest.stockRamdiskHash == stockHash,
              manifest.allowShell == allowShell,
              (try? hash(directory.appendingPathComponent("ramdisk.img"))) == manifest.patchedHash,
              (try? hash(directory.appendingPathComponent("ksud-android"))) == manifest.guestToolHash else { return false }
        return true
    }

    public func activate(_ prepared: Prepared, adb: ADBClient) async throws {
        let guestPath = "/data/local/tmp/mandroid-ksud"
        _ = try await adb.run(["push", prepared.guestTool.path, guestPath])
        defer { Task { _ = try? await adb.shell("rm -f \(guestPath)") } }
        _ = try await adb.shell("chmod 755 \(guestPath)")
        let version = try await adb.shell("\(guestPath) debug version")
        guard version.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Kernel Version: 32601" }) else {
            throw Failure("The patched kernel did not activate. Turn KernelSU off and restart to use the stock image.")
        }
        let installed = try await adb.listThirdPartyPackages().contains(Self.managerPackage)
        if !installed {
            try await adb.install(apk: prepared.manager)
        }
        // Opening the official Manager installs its userspace daemon. Root
        // grants remain under the user's control in Manager; shell root, when
        // the ramdisk was patched for it, comes from the boot image instead.
        guard let component = try await adb.launcherComponent(of: Self.managerPackage) else {
            throw Failure("Could not open KernelSU Manager.")
        }
        try await adb.startActivity(component: component, displayID: 0)
    }
}
