import Foundation

/// One short line on what a media model is good at, taken from its own description. The first entry
/// whose parts all appear in the id wins, so specific entries go before general ones. Models not
/// listed show no note.
enum MediaModelNotes {
    private static let notes: [(parts: [String], note: String)] = [
        // Image
        (["recraft/recraft-v4-styles"], "Copies the style of an image you give"),
        (["recraft/", "-vector"], "SVG output for logos and icons"),
        (["recraft/recraft-v4.1-flash"], "Very fast and cheap"),
        (["recraft/recraft-v4.1-utility"], "General purpose"),
        (["recraft/"], "Polished, design-led look"),
        (["krea/k3-edit"], "Edits only: needs an image"),
        (["krea/krea-2-large"], "Rawer, more textured look"),
        (["krea/krea-2-medium-turbo"], "Quick drafts for design ideas"),
        (["krea/krea-2-medium"], "Balanced all-rounder"),
        (["qwen/qwen-image-3"], "Sharp text, even tiny print"),
        (["qwen/qwen-image-2.1-turbo"], "Fast and cheap; edits too"),
        (["qwen/qwen-image-2.1-pro"], "Higher-quality Qwen; edits too"),
        (["black-forest-labs/flux.2-flex"], "Complex text and typography"),
        (["black-forest-labs/flux.2-klein"], "Fastest, cheapest FLUX"),
        (["black-forest-labs/flux-3-image-klein"], "Keeps characters consistent across edits"),
        (["black-forest-labs/flux-3-image"], "FLUX flagship; up to 10 reference images"),
        (["black-forest-labs/flux.2-max"], "Top FLUX.2 quality"),
        (["openai/gpt-image-2.5-flare"], "Fast everyday GPT Image"),
        (["openai/gpt-image-2.5-sunburst"], "Detailed, precise GPT Image"),
        (["openai/gpt-image"], "Accurate text, transparent backgrounds"),
        (["openai/gpt-5"], "GPT thinks through the prompt, then draws"),
        (["meta/muse-image"], "Plans the picture before drawing it"),
        (["google/gemini-nano-banana-2.1"], "Good at putting products in new scenes"),
        (["google/gemini-3.1-flash-lite-image"], "Fastest, cheapest Gemini"),
        (["google/gemini-3.1-flash-image"], "Pro quality at Flash speed"),
        (["google/gemini-3-pro-image"], "Uses real-world knowledge"),
        (["google/gemini-2.5-flash-image"], "The original Nano Banana"),
        (["tencent/hy-image"], "Takes up to 20 reference images"),
        (["bytedance-seed/seedream-5-0-lite"], "Looks things up on the web"),
        (["bytedance-seed/seedream-5-0-pro"], "Lifelike scenes, precise edits"),
        (["bytedance-seed/seedream-5-0-flash"], "Fast and cheap"),
        (["bytedance-seed/seedream-4.5"], "Keeps subjects intact when editing"),
        (["sourceful/riverflow"], "Strong at design, logos and text"),
        (["microsoft/mai-image-2.6-flash"], "Near 2.6 quality, faster and cheaper"),
        (["microsoft/mai-image-2.6"], "Design-ready visuals"),
        (["x-ai/grok-imagine-image-quality"], "Photorealistic"),
        // Video
        (["heygen/avatar"], "Talking avatars"),
        (["black-forest-labs/flux-video-edit"], "Edits a video you give"),
        (["black-forest-labs/flux-video-upscale"], "Upscales a video you give"),
        (["runway/aleph"], "Restyles a video you give"),
        (["google/veo-3.1-lite"], "Cheapest Veo"),
        (["google/veo-3.1-fast"], "Faster, cheaper Veo"),
        (["google/veo"], "Google's flagship, with sound"),
        (["x-ai/grok-imagine-video-1.5-lite"], "Fast and cheap"),
        (["bytedance/seedance-2.0-mini"], "Cheapest Seedance"),
        (["bytedance/seedance-2.0-fast"], "Faster Seedance"),
        // Voice
        (["google/gemini"], "Follows directions on tone and pace"),
        (["elevenlabs/eleven-flash"], "Lowest delay ElevenLabs"),
        (["elevenlabs/"], "Very natural voices"),
        (["hexgrad/kokoro"], "Tiny open model, very cheap"),
        ([":free"], "Free"),
        (["sesame/csm"], "Conversational"),
    ]

    static func note(for id: String) -> String? {
        notes.first { $0.parts.allSatisfy(id.contains) }?.note
    }
}
