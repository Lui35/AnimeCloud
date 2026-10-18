import Foundation

public struct Anime4KShaderStage: Sendable {
    public let name: String
    public let glsl: String

    public init(name: String, glsl: String) {
        self.name = name
        self.glsl = glsl
    }
}

public struct Anime4KShaderProgram: Sendable {
    public let name: String
    public let stages: [Anime4KShaderStage]
    public let stageFiles: [String]

    public init(name: String, stages: [Anime4KShaderStage], stageFiles: [String]) {
        self.name = name
        self.stages = stages
        self.stageFiles = stageFiles
    }
}

public enum Anime4KShaderCatalog {
    public static func program(for preset: Anime4KPreset) throws -> Anime4KShaderProgram {
        let files = stageFiles(for: preset)
        let stages = try files.map { relative in
            Anime4KShaderStage(name: relative, glsl: try loadSource(relativePath: relative))
        }
        return Anime4KShaderProgram(name: modeName(for: preset), stages: stages, stageFiles: files)
    }

    static func stageFiles(for preset: Anime4KPreset) -> [String] {
        switch preset {
        case .modeAFast:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_M.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .modeBFast:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_Soft_M.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .modeCFast:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .modeAAFast:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_M.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
                "Restore/Anime4K_Restore_CNN_S.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .modeBBFast:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_Soft_M.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Restore/Anime4K_Restore_CNN_Soft_S.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .modeCAFast:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Restore/Anime4K_Restore_CNN_S.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .modeAHQ:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_VL.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        case .modeBHQ:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_Soft_VL.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        case .modeCHQ:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        case .modeAAHQ:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_VL.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
                "Restore/Anime4K_Restore_CNN_M.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        case .modeBBHQ:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Restore/Anime4K_Restore_CNN_Soft_VL.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Restore/Anime4K_Restore_CNN_Soft_M.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        case .modeCAHQ:
            return [
                "Restore/Anime4K_Clamp_Highlights.glsl",
                "Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x2.glsl",
                "Upscale/Anime4K_AutoDownscalePre_x4.glsl",
                "Restore/Anime4K_Restore_CNN_M.glsl",
                "Upscale/Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        }
    }

    static func loadSource(relativePath: String) throws -> String {
        guard let url = Bundle.module.url(forResource: "glsl/\(relativePath)", withExtension: nil) else {
            throw Anime4KError.shaderResourceMissing(relativePath)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func modeName(for preset: Anime4KPreset) -> String {
        "Anime4K \(preset.displayName)"
    }
}
