import Foundation

/// Everything that exists while one emulator instance is booted.
public struct EmulatorSession: Sendable {
    public let options: EmulatorLaunchOptions
    public let process: EmulatorProcess
    public let adb: ADBClient
    public let connection: EmulatorConnection
    public let client: EmulatorClient
    public let displays: DisplaySlotPool
    public let input: InputChannel
    public let scroll: ScrollChannel
    public let router: InputRouter
    public let frames: any FrameStream
    /// Built-in display size in pixels (from the AVD).
    public let deviceWidth: Int
    public let deviceHeight: Int
    public let deviceDpi: Int
}
