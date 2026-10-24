import Foundation

/// Arena Elo from Artificial Analysis's public leaderboards (artificialanalysis.ai, read 23 Oct 2026),
/// keyed by OpenRouter model id. The live benchmark feed the app also reads covers only part of these
/// boards, lags behind them, and pins some scores on the wrong model, so this snapshot ranks first and
/// the feed fills in models it doesn't list. LMArena's image and video boards agreed on the leaders.
/// `MediaArenaFeed` brings the same boards fresh from AA's API and replaces this snapshot board by
/// board once loaded, so this is the fallback for a first launch offline.
enum MediaModelResearch {
    static let source = "Artificial Analysis"
    static let sourceURL = URL(string: "https://artificialanalysis.ai")!
    static let asOf = "Oct 2026"

    enum Board: String {
        case textToImage = "text-to-image", imageEditing = "image editing"
        case textToVideo = "text-to-video", imageToVideo = "image-to-video"
        case textToSpeech = "text-to-speech"

        /// The board's name in AA's API and in `MediaArenaFeed`.
        var endpoint: String { self == .imageEditing ? "image-editing" : rawValue }
    }

    static func elo(_ board: Board, _ id: String) -> Double? { scores[board]?[id] }

    private static let scores: [Board: [String: Double]] = [
        .textToImage: [
            "openai/gpt-image-2.5-sunburst": 1222,
            "openai/gpt-image-2.5-flare": 1207,
            "openai/gpt-image-2": 1186,
            "google/gemini-nano-banana-2.1": 1176,
            "microsoft/mai-image-2.6": 1166,
            "x-ai/grok-imagine-image-2.0": 1166,
            "google/gemini-3.1-flash-image": 1140,
            "meta/muse-image": 1127,
            "microsoft/mai-image-2.6-flash": 1119,
            "google/gemini-3-pro-image": 1118,
            "microsoft/mai-image-2.5": 1118,
            "black-forest-labs/flux-3-image": 1117,
            "microsoft/mai-image-2.5-pro": 1114,
            "google/gemini-3.1-flash-lite-image": 1107,
            "bytedance-seed/seedream-5-0-pro": 1100,
            "qwen/qwen-image-3-pro": 1095,
            "qwen/qwen-image-3": 1070,
            "qwen/qwen-image-2.1-pro": 1056,
            "x-ai/grok-imagine-image-quality": 1049,
            "black-forest-labs/flux-3-image-klein": 1043,
            "krea/krea-2-large": 1034,
            "qwen/qwen-image-2.1-turbo": 1029,
            "recraft/recraft-v4.1-utility": 1026,
            "bytedance-seed/seedream-4.5": 1026,
            "black-forest-labs/flux.2-flex": 1026,
            "black-forest-labs/flux.2-max": 1021,
            "krea/krea-2-medium-turbo": 1020,
            "recraft/recraft-v4.1-utility-pro": 1017,
            "bytedance-seed/seedream-5-0-lite": 1017,
            "openai/gpt-image-1": 1013,
            "krea/krea-2-medium": 1012,
            "black-forest-labs/flux.2-pro": 1003,
            "google/gemini-2.5-flash-image": 985,
            "tencent/hy-image-v3.5-preview": 970,
            "recraft/recraft-v4.1-flash": 949,
            "openai/gpt-image-1-mini": 936,
            "black-forest-labs/flux.2-klein-4b": 837,
        ],
        .imageEditing: [
            "openai/gpt-image-2.5-sunburst": 1199,
            "openai/gpt-image-2.5-flare": 1182,
            "microsoft/mai-image-2.6": 1151,
            "google/gemini-nano-banana-2.1": 1151,
            "microsoft/mai-image-2.6-flash": 1144,
            "openai/gpt-image-2": 1136,
            "bytedance-seed/seedream-5-0-pro": 1131,
            "meta/muse-image": 1129,
            "microsoft/mai-image-2.5": 1127,
            "google/gemini-3.1-flash-image": 1123,
            "microsoft/mai-image-2.5-pro": 1123,
            "black-forest-labs/flux-3-image": 1122,
            "x-ai/grok-imagine-image-2.0": 1117,
            "google/gemini-3-pro-image": 1108,
            "x-ai/grok-imagine-image-quality": 1095,
            "tencent/hy-image-v3.5-preview": 1093,
            "qwen/qwen-image-3-pro": 1091,
            "black-forest-labs/flux-3-image-klein": 1072,
            "qwen/qwen-image-2.1-pro": 1069,
            "qwen/qwen-image-3": 1068,
            "qwen/qwen-image-2.1-turbo": 1064,
            "bytedance-seed/seedream-5-0-lite": 1062,
            "google/gemini-3.1-flash-lite-image": 1054,
            "bytedance-seed/seedream-4.5": 1043,
            "black-forest-labs/flux.2-pro": 1012,
            "black-forest-labs/flux.2-flex": 999,
            "black-forest-labs/flux.2-max": 999,
            "openai/gpt-image-1": 995,
            "google/gemini-2.5-flash-image": 984,
            "black-forest-labs/flux.2-klein-4b": 938,
            "openai/gpt-image-1-mini": 934,
        ],
        // With audio, which is how these models are usually run.
        .textToVideo: [
            "alibaba/wan-3.0": 1175,
            "heygen/heygen-video-1": 1160,
            "minimax/hailuo-3": 1158,
            "bytedance/seedance-2.5": 1158,
            "minimax/hailuo-3-max": 1154,
            "black-forest-labs/flux-3-video": 1145,
            "bytedance/seedance-2.0": 1136,
            "x-ai/grok-imagine-video-1.5": 1056,
            "alibaba/happyhorse-1.1": 1051,
            "alibaba/wan-2.7": 1037,
            "alibaba/happyhorse-1.0": 1033,
            "kwaivgi/kling-v3.0-pro": 1000,
            "x-ai/grok-imagine-video-1.5-lite": 992,
            "google/veo-3.1": 963,
            "google/veo-3.1-fast": 960,
            "google/veo-3.1-lite": 950,
        ],
        .imageToVideo: [
            "minimax/hailuo-3": 1140,
            "bytedance/seedance-2.5": 1138,
            "alibaba/wan-3.0": 1127,
            "minimax/hailuo-3-max": 1125,
            "bytedance/seedance-2.0": 1121,
            "black-forest-labs/flux-3-video": 1086,
            "x-ai/grok-imagine-video-1.5": 1067,
            "alibaba/happyhorse-1.1": 1061,
            "alibaba/happyhorse-1.0": 1042,
            "alibaba/wan-2.7": 1034,
            "google/veo-3.1": 1028,
            "google/veo-3.1-fast": 1017,
            "kwaivgi/kling-v3.0-pro": 1000,
        ],
        .textToSpeech: [
            "elevenlabs/eleven-v4-turbo": 1335,
            "elevenlabs/eleven-v4": 1329,
            "google/gemini-3.8-flash-tts": 1278,
            "qwen/qwen-audio-3.0-tts-plus": 1265,
            "google/gemini-3.8-flash-lite-tts": 1251,
            "fish-audio/drama-3": 1248,
            "mistralai/voxtral-mini-tts-3-0": 1218,
            "elevenlabs/eleven-v3-conversational": 1214,
            "google/gemini-3.1-flash-tts-preview": 1213,
            "fish-audio/s2.1-pro": 1189,
            "fish-audio/s2.1-pro-free:free": 1189,
            "elevenlabs/eleven-v3": 1183,
            "minimax/speech-2.8-hd": 1174,
            "minimax/speech-2.8-turbo": 1155,
            "x-ai/grok-voice-tts-1.0": 1150,
            "fish-audio/s2-pro": 1112,
            "elevenlabs/eleven-turbo-v2.5": 1098,
            "elevenlabs/eleven-multilingual-v2": 1096,
            "mistralai/voxtral-mini-tts-2603": 1091,
            "fish-audio/s1": 1086,
            "elevenlabs/eleven-flash-v2.5": 1077,
            "hexgrad/kokoro-82m": 1065,
            "deepgram/flux-tts": 1052,
        ],
    ]

    /// The creator's price for one image at about 1K and default settings (the settings the scores
    /// were measured at). Used for models OpenRouter bills by token, where the app can only guess how
    /// many tokens an image takes; OpenAI's run several times the guess.
    static let imagePrice: [String: Double] = [
        "openai/gpt-image-2.5-sunburst": 0.2107,
        "openai/gpt-image-2.5-flare": 0.2107,
        "openai/gpt-image-2": 0.211,
        "openai/gpt-image-1": 0.167,
        "openai/gpt-image-1-mini": 0.011,
        "google/gemini-nano-banana-2.1": 0.0336,
        "google/gemini-3.1-flash-image": 0.067,
        "google/gemini-3-pro-image": 0.134,
        "google/gemini-3.1-flash-lite-image": 0.0336,
        "google/gemini-2.5-flash-image": 0.039,
        "microsoft/mai-image-2.6": 0.0389,
        "microsoft/mai-image-2.6-flash": 0.0195,
        "microsoft/mai-image-2.5": 0.0481,
        "microsoft/mai-image-2.5-pro": 0.1085,
        "tencent/hy-image-v3.5-preview": 0.024,
    ]
}
