import Metal

public enum Anime4KMetalLibrary {
    public static func makeDefaultLibrary(device: MTLDevice) throws -> MTLLibrary {
        do {
            return try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            throw Anime4KError.shaderCompilationFailed(error.localizedDescription)
        }
    }
}
