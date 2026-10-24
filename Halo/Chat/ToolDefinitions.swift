import Foundation

enum ToolDefinitions {
    static func tools(for caps: Set<ToolCapability>, webSearch: Bool) -> [ToolSpec] {
        var tools: [ToolSpec] = []
        if caps.contains(.images) { tools.append(generateImage) }
        if caps.contains(.video) { tools.append(generateVideo) }
        if caps.contains(.speech) { tools.append(generateSpeech) }
        if caps.contains(.code) { tools.append(contentsOf: [runCode, shell]) }
        if caps.contains(.artifacts) { tools.append(contentsOf: [createArtifact, updateArtifact]) }
        if webSearch {
            tools.append(.server(type: "openrouter:web_search", parameters: ["max_results": 6, "search_context_size": "medium"]))
        }
        return tools
    }

    static let generateImage = ToolSpec.function(
        name: ToolName.generateImage.rawValue,
        description: "Generate or edit images with a dedicated image model. Use when the user wants a picture, illustration, logo, photo edit, etc. Write a vivid, specific prompt (subject, style, composition, lighting). To edit or riff on existing images, pass their ids (e.g. img_ab12cd) in reference_image_ids. The user reviews and approves each request and may change the prompt or model.",
        parameters: [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "Detailed image prompt, or edit instructions when reference images are given."],
                "aspect_ratio": ["type": "string", "enum": ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9"], "description": "Aspect ratio. Default 1:1."],
                "count": ["type": "integer", "minimum": 1, "maximum": 4, "description": "Number of images (default 1)."],
                "transparent_background": ["type": "boolean", "description": "A cut-out with no background (logos, icons, stickers). Only some models can; the user can change it."],
                "reference_image_ids": ["type": "array", "items": ["type": "string"], "description": "Ids of attached or previously generated images to edit / use as reference."],
            ],
            "required": ["prompt"],
        ]
    )

    static let generateVideo = ToolSpec.function(
        name: ToolName.generateVideo.rawValue,
        description: "Generate a short video clip with a video model. Video is slow (1-5 minutes) and expensive, so only use it when the user explicitly wants a video. Describe motion, camera, style and sound. The user approves first.",
        parameters: [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "Detailed description of the shot: subject, action, camera movement, style, audio."],
                "duration_seconds": ["type": "integer", "minimum": 2, "maximum": 15, "description": "Clip length in seconds (default 6)."],
                "aspect_ratio": ["type": "string", "enum": ["16:9", "9:16", "1:1"], "description": "Default 16:9."],
                "first_frame_image_id": ["type": "string", "description": "Optional image id to animate (image-to-video)."],
            ],
            "required": ["prompt"],
        ]
    )

    static let generateSpeech = ToolSpec.function(
        name: ToolName.generateSpeech.rawValue,
        description: "Turn text into natural spoken audio (text-to-speech) and play it for the user. Use when asked to say, read aloud, narrate, pronounce, or make audio.",
        parameters: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Exactly what should be spoken."],
                "voice": ["type": "string", "description": "Optional voice name. Leave empty for the user's default voice."],
                "style_instructions": ["type": "string", "description": "Optional delivery notes, e.g. 'warm and calm', 'excited sports commentator'."],
            ],
            "required": ["text"],
        ]
    )

    static let runCode = ToolSpec.function(
        name: ToolName.runCode.rawValue,
        description: "Execute code on the user's device and get stdout/result back. Python runs in Pyodide (numpy, pandas, matplotlib, sympy, scipy load on demand; no network, no input()); matplotlib figures are shown to the user automatically. JavaScript runs in a sandbox without DOM or network. Use it for any calculation beyond one simple step (unit conversions, multi-step math, large or precise numbers, dates, statistics) instead of working it out in your head, and quote results from its output. Also for data analysis, charts and checking code.",
        parameters: [
            "type": "object",
            "properties": [
                "language": ["type": "string", "enum": ["python", "javascript"]],
                "code": ["type": "string", "description": "Complete program. Print results you need to see."],
            ],
            "required": ["language", "code"],
        ]
    )

    static let shell = ToolSpec.function(
        name: ToolName.shell.rawValue,
        description: "Run a command in a minimal pretend shell on the user's device, mainly to call web APIs and fetch URLs. Commands: curl, wget, jq, grep, head, tail, wc, sort, uniq, cat, echo, printf, base64, date, sleep. Pipes, &&, ||, ; and NAME=value variables work. There is no filesystem (no files, no -o, no > redirects except to /dev/null) and no other programs. curl supports -X -H -d --data-raw --data-urlencode --json -G -i -I -s -f -L -u -A -m -w; only https:// URLs work off the local network. jq supports paths, pipes, [..], {..}, map, keys, length, -r, -c. Output over 16k characters is cut, so filter big responses with jq or head. Run `help` for details.",
        parameters: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "The command line, e.g. curl -s 'https://api.github.com/repos/apple/swift' | jq '{stars: .stargazers_count, forks}'"],
            ],
            "required": ["command"],
        ]
    )

    static let createArtifact = ToolSpec.function(
        name: ToolName.createArtifact.rawValue,
        description: "Create a standalone document or app shown to the user in a full-screen canvas with live preview, version history and export. Use for substantial content: documents/essays/reports (markdown), complete programs (code), web pages (html: one self-contained file with inline CSS/JS), React components (react: a single file with `export default function App()`, Tailwind classes available), SVG graphics (svg) and Mermaid diagrams (mermaid). Do not repeat the content in chat afterwards; briefly say what you made.",
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Short title."],
                "type": ["type": "string", "enum": ["markdown", "code", "html", "react", "svg", "mermaid"]],
                "language": ["type": "string", "description": "Programming language when type is code (e.g. swift, python)."],
                "content": ["type": "string", "description": "The full content."],
            ],
            "required": ["title", "type", "content"],
        ]
    )

    static let updateArtifact = ToolSpec.function(
        name: ToolName.updateArtifact.rawValue,
        description: "Revise an existing artifact, creating a new version. For small changes pass `edits` (exact find/replace pairs; each `find` must match the current text exactly once). For large changes pass the full new `content`.",
        parameters: [
            "type": "object",
            "properties": [
                "artifact_id": ["type": "string", "description": "Id of the artifact to update."],
                "edits": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["find": ["type": "string"], "replace": ["type": "string"]],
                        "required": ["find", "replace"],
                    ],
                ],
                "content": ["type": "string", "description": "Full replacement content (instead of edits)."],
                "summary": ["type": "string", "description": "One-line description of the change."],
            ],
            "required": ["artifact_id"],
        ]
    )
}
