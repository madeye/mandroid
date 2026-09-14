import Foundation

/// Creates and inspects AVDs under the isolated `ANDROID_AVD_HOME`.
public struct AVDStore: Sendable {
    public let paths: SDKPaths
    public init(paths: SDKPaths) { self.paths = paths }

    public func directory(for name: String) -> URL {
        paths.avdHome.appendingPathComponent("\(name).avd", isDirectory: true)
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: name).appendingPathComponent("config.ini").path)
    }

    /// Writes the AVD files. Existing user data (`userdata-qemu.img`,
    /// snapshots) is preserved; only the ini files are (re)written.
    /// The emulator appends `hw.displayN.*` keys at runtime; we strip them so
    /// every boot starts with display 0 only.
    /// Returns true when an existing display or GPU profile changed and its old
    /// quickboot snapshot must not be loaded. User data is never reset.
    @discardableResult
    public func write(_ config: AVDConfig) throws -> Bool {
        let dir = directory(for: config.name)
        let ini = dir.appendingPathComponent("config.ini")
        let previous = try? String(contentsOf: ini, encoding: .utf8)
        let rendered = config.renderConfigINI()
        let snapshotKeys = ["hw.lcd.width", "hw.lcd.height", "hw.lcd.density", "hw.initialOrientation", "hw.gpu.mode", "mandroid.gpu.backend"]
        func value(_ key: String, in text: String) -> String? {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        let profileChanged = previous.map { old in
            snapshotKeys.contains { value($0, in: old) != value($0, in: rendered) }
        } ?? false
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rendered.write(to: ini, atomically: true, encoding: .utf8)
        try config.renderPointerINI(avdDirectory: dir)
            .write(to: paths.avdHome.appendingPathComponent("\(config.name).ini"), atomically: true, encoding: .utf8)
        return profileChanged
    }

    /// Removes `hw.display1..3` lines the emulator may have persisted.
    public func stripPersistedDisplays(_ name: String) throws {
        let file = directory(for: name).appendingPathComponent("config.ini")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("hw.display") }
        let out = kept.joined(separator: "\n")
        if out != text { try out.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Removes the quickboot snapshot (used after a failed or corrupt load).
    public func deleteQuickbootSnapshot(_ name: String) {
        try? FileManager.default.removeItem(at: directory(for: name).appendingPathComponent("snapshots/default_boot", isDirectory: true))
    }

    /// Deletes the AVD entirely (cold start from scratch).
    public func delete(_ name: String) throws {
        try? FileManager.default.removeItem(at: directory(for: name))
        try? FileManager.default.removeItem(at: paths.avdHome.appendingPathComponent("\(name).ini"))
    }
}
