import Foundation

public enum Anime4KError: Error, Sendable, LocalizedError {
    case metalUnavailable
    case unsupportedPixelFormat(OSType)
    case invalidDimensions(width: Int, height: Int)
    case shaderResourceMissing(String)
    case shaderCompilationFailed(String)
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal is unavailable"
        case let .unsupportedPixelFormat(format):
            return "Unsupported pixel format: \(format)"
        case let .invalidDimensions(width, height):
            return "Invalid dimensions: \(width)x\(height)"
        case let .shaderResourceMissing(path):
            return "Shader resource missing: \(path)"
        case let .shaderCompilationFailed(message):
            return "Shader compilation failed: \(message)"
        case let .processingFailed(message):
            return "Processing failed: \(message)"
        }
    }
}
