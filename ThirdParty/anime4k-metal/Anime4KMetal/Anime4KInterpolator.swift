import Anime4KMetalCore
import CoreVideo
import Foundation

public final class Anime4KInterpolator: @unchecked Sendable {
    private let engine: Anime4KHostEngine
    private let configuration: Anime4KConfiguration
    private let queue = DispatchQueue(label: "anime4k.metal.interpolator", qos: .userInitiated)
    private var generation: Int64 = 0

    public init(configuration: Anime4KConfiguration = .init()) throws {
        self.configuration = configuration
        engine = try Anime4KHostEngine(preferredDevice: configuration.preferredDevice)
    }

    public init(
        configuration: Anime4KConfiguration = .init(),
        engine: Anime4KHostEngine
    ) {
        self.configuration = configuration
        self.engine = engine
    }

    public func reset() {
        queue.sync {
            generation += 1
            engine.reset()
        }
    }

    public func enhance(pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        try enhance(
            pixelBuffer: pixelBuffer,
            preset: configuration.preset,
            maxOutputWidth: configuration.maxOutputWidth,
            maxOutputHeight: configuration.maxOutputHeight,
            abCompareEnabled: configuration.abCompareEnabled
        )
    }

    public func enhance(
        pixelBuffer: CVPixelBuffer,
        preset: Anime4KPreset,
        maxOutputWidth: Int,
        maxOutputHeight: Int,
        abCompareEnabled: Bool = false
    ) throws -> CVPixelBuffer {
        try queue.sync {
            guard let enhanced = engine.enhance(
                pixelBuffer: pixelBuffer,
                timestamp: 0,
                generation: generation,
                preset: preset,
                abCompareEnabled: abCompareEnabled,
                maxOutputWidth: maxOutputWidth,
                maxOutputHeight: maxOutputHeight
            ) else {
                throw Anime4KError.processingFailed("enhancement returned no frame")
            }
            return enhanced
        }
    }
}
