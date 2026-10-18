import Foundation
@preconcurrency import Metal

public struct Anime4KConfiguration: Sendable {
    public var preset: Anime4KPreset
    public var preferredDevice: MTLDevice?
    public var maxOutputWidth: Int
    public var maxOutputHeight: Int
    public var abCompareEnabled: Bool

    public init(
        preset: Anime4KPreset = .modeAFast,
        preferredDevice: MTLDevice? = nil,
        maxOutputWidth: Int = 2560,
        maxOutputHeight: Int = 1440,
        abCompareEnabled: Bool = false
    ) {
        self.preset = preset
        self.preferredDevice = preferredDevice
        self.maxOutputWidth = maxOutputWidth
        self.maxOutputHeight = maxOutputHeight
        self.abCompareEnabled = abCompareEnabled
    }
}
