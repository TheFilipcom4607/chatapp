import Foundation

enum ToolDefinitions {
    static func tools(for caps: Set<ToolCapability>, search: SearchConfig?, modelID: String) -> [ToolSpec] {
        var tools: [ToolSpec] = []
        if caps.contains(.images) { tools.append(generateImage) }
        if caps.contains(.video) { tools.append(generateVideo) }
        if caps.contains(.speech) { tools.append(generateSpeech) }
        if caps.contains(.code) { tools.append(contentsOf: [runCode, shell]) }
        if caps.contains(.artifacts) { tools.append(contentsOf: [createArtifact, updateArtifact]) }
        if caps.contains(.webPages) { tools.append(readWebPage) }
        if caps.contains(.calendar) { tools.append(contentsOf: [listEvents, listReminders, createEvent, createReminder]) }
        if caps.contains(.location) { tools.append(contentsOf: [getLocation, getWeather]) }
        if caps.contains(.maps) { tools.append(contentsOf: [searchPlaces, getDirections]) }
        if caps.contains(.appLinks) { tools.append(openInApp) }
        if caps.contains(.device) { tools.append(deviceInfo) }
        if let search {
            tools.append(.server(type: "openrouter:web_search", parameters: search.toolParameters(modelID: modelID)))
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

    static let readWebPage = ToolSpec.function(
        name: ToolName.readWebPage.rawValue,
        description: "Fetch a web page and read its text (scripts, menus, headers and footers removed; headings kept). Use it for a link the user gives or one found by search when the snippet isn't enough. Long pages come in parts: pass `start` from the note at the end to read on.",
        parameters: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "The https:// address."],
                "start": ["type": "integer", "minimum": 0, "description": "Character offset to continue from (default 0)."],
            ],
            "required": ["url"],
        ]
    )

    static let deviceInfo = ToolSpec.function(
        name: ToolName.deviceInfo.rawValue,
        description: "The user's iPhone right now: battery level and charging state, Low Power Mode, free storage, iOS version, device model, language and region, time zone and the exact local time.",
        parameters: ["type": "object", "properties": [:]]
    )

    static let openInApp = ToolSpec.function(
        name: ToolName.openInApp.rawValue,
        description: "Show a button that opens another app: Maps (a search or address), Safari (a URL or web search), Music (a search) or Shortcuts (run a shortcut by name). The user taps it; nothing opens by itself.",
        parameters: [
            "type": "object",
            "properties": [
                "app": ["type": "string", "enum": ["maps", "safari", "music", "shortcuts"]],
                "query": ["type": "string", "description": "What to search for, the address, or the shortcut's name."],
                "url": ["type": "string", "description": "For Safari: the https:// page to open."],
            ],
            "required": ["app"],
        ]
    )

    static let getLocation = ToolSpec.function(
        name: ToolName.getLocation.rawValue,
        description: "The user's current location: city, region and country with coordinates rounded to about 1 km. Only call it when the answer depends on where they are (nearby, local time, weather here). Set precise only when street-level accuracy is needed. iOS asks the user the first time.",
        parameters: [
            "type": "object",
            "properties": [
                "precise": ["type": "boolean", "description": "Street-level coordinates and address instead of city level."],
            ],
        ]
    )

    static let getWeather = ToolSpec.function(
        name: ToolName.getWeather.rawValue,
        description: "Current weather, the next 24 hours and a 7-day forecast (Open-Meteo). Give a place name, or coordinates; with neither it uses the user's location.",
        parameters: [
            "type": "object",
            "properties": [
                "place": ["type": "string", "description": "City or place name, e.g. 'Kraków' or 'Lisbon, Portugal'."],
                "latitude": ["type": "number"],
                "longitude": ["type": "number"],
            ],
        ]
    )

    static let searchPlaces = ToolSpec.function(
        name: ToolName.searchPlaces.rawValue,
        description: "Find places with Apple Maps: shops, restaurants, addresses, landmarks. Returns names, addresses, distance, phone and website. Searches near the user unless `near` names somewhere else.",
        parameters: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "What to look for, e.g. 'pharmacy open now' or 'ramen'."],
                "near": ["type": "string", "description": "Optional place to search around instead of the user's location."],
            ],
            "required": ["query"],
        ]
    )

    static let getDirections = ToolSpec.function(
        name: ToolName.getDirections.rawValue,
        description: "Travel time and distance from the user's location (or `from`) to a place, by car, on foot or by public transport, with a button to open the route in Maps.",
        parameters: [
            "type": "object",
            "properties": [
                "to": ["type": "string", "description": "Destination: a place name or address."],
                "from": ["type": "string", "description": "Optional start; the user's location by default."],
                "mode": ["type": "string", "enum": ["driving", "walking", "transit"], "description": "Default driving."],
            ],
            "required": ["to"],
        ]
    )

    static let listEvents = ToolSpec.function(
        name: ToolName.listEvents.rawValue,
        description: "The user's calendar events from now on: title, time, calendar and location. iOS asks for access the first time.",
        parameters: [
            "type": "object",
            "properties": [
                "days": ["type": "integer", "minimum": 1, "maximum": 31, "description": "How many days ahead (default 7)."],
            ],
        ]
    )

    static let listReminders = ToolSpec.function(
        name: ToolName.listReminders.rawValue,
        description: "The user's open reminders with their lists and due dates. iOS asks for access the first time.",
        parameters: ["type": "object", "properties": [:]]
    )

    static let createEvent = ToolSpec.function(
        name: ToolName.createEvent.rawValue,
        description: "Add an event to the user's calendar. They see a card to check or change it and approve it first. Times are local, ISO 8601 like 2026-10-25T15:00.",
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "start": ["type": "string", "description": "Local start, e.g. 2026-10-25T15:00, or a date for an all-day event."],
                "end": ["type": "string", "description": "Local end; one hour after the start by default."],
                "all_day": ["type": "boolean"],
                "location": ["type": "string"],
                "notes": ["type": "string"],
                "calendar": ["type": "string", "description": "Calendar name; the default calendar if left out."],
            ],
            "required": ["title", "start"],
        ]
    )

    static let createReminder = ToolSpec.function(
        name: ToolName.createReminder.rawValue,
        description: "Add a reminder. The user sees a card to check or change it and approves it first.",
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "due": ["type": "string", "description": "Optional local due time, e.g. 2026-10-25T09:00."],
                "notes": ["type": "string"],
                "list": ["type": "string", "description": "Reminder list name; the default list if left out."],
            ],
            "required": ["title"],
        ]
    )
}
