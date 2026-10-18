import Foundation

public enum Anime4KPreset: String, CaseIterable, Identifiable, Sendable {
    case modeAFast
    case modeBFast
    case modeCFast
    case modeAAFast
    case modeBBFast
    case modeCAFast
    case modeAHQ
    case modeBHQ
    case modeCHQ
    case modeAAHQ
    case modeBBHQ
    case modeCAHQ

    public var id: String { rawValue }

    public static var availablePresets: [Anime4KPreset] {
        #if os(iOS)
            return [.modeAFast, .modeBFast, .modeCFast, .modeAAFast, .modeBBFast, .modeCAFast]
        #else
            return Anime4KPreset.allCases
        #endif
    }

    public var displayName: String {
        switch self {
        case .modeAFast: return "Mode A (Fast)"
        case .modeBFast: return "Mode B (Fast)"
        case .modeCFast: return "Mode C (Fast)"
        case .modeAAFast: return "Mode A+A (Fast)"
        case .modeBBFast: return "Mode B+B (Fast)"
        case .modeCAFast: return "Mode C+A (Fast)"
        case .modeAHQ: return "Mode A (HQ)"
        case .modeBHQ: return "Mode B (HQ)"
        case .modeCHQ: return "Mode C (HQ)"
        case .modeAAHQ: return "Mode A+A (HQ)"
        case .modeBBHQ: return "Mode B+B (HQ)"
        case .modeCAHQ: return "Mode C+A (HQ)"
        }
    }
}
