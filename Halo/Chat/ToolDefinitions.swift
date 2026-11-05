import Foundation

enum ToolDefinitions {
    static func tools(for caps: Set<ToolCapability>, search: SearchConfig?, modelID: String,
                      media: MediaModels = MediaModels()) -> [ToolSpec] {
        var tools: [ToolSpec] = []
        if caps.contains(.images) { tools.append(generateImage(media)) }
        if caps.contains(.video) { tools.append(generateVideo(media)) }
        if caps.contains(.speech) { tools.append(generateSpeech(media)) }
        if caps.contains(.code) { tools.append(contentsOf: [runCode, shell]) }
        #if os(macOS)
        if caps.contains(.code) { tools.append(runCommand) }
        #endif
        if caps.contains(.artifacts) { tools.append(contentsOf: [createArtifact, updateArtifact]) }
        if caps.contains(.webPages) { tools.append(readWebPage) }
        if caps.contains(.calendar) { tools.append(contentsOf: [listEvents, listReminders, createEvent, createReminder]) }
        if caps.contains(.location) { tools.append(contentsOf: [getLocation, getWeather]) }
        if caps.contains(.maps) { tools.append(contentsOf: [searchPlaces, getDirections]) }
        if caps.contains(.appLinks) { tools.append(openInApp) }
        if caps.contains(.device) { tools.append(deviceInfo) }
        #if os(macOS)
        if caps.contains(.browser) { tools.append(contentsOf: [browserOpen, browserRead, browserClick, browserType, browserPress, browserScroll]) }
        #endif
        if let search {
            tools.append(.server(type: "openrouter:web_search", parameters: search.toolParameters(modelID: modelID)))
        }
        return tools
    }

    // MARK: Chrome (Mac)

    static let browserOpen = ToolSpec.function(
        name: ToolName.browserOpen.rawValue,
        description: "Open a URL in Chrome (real Chrome with its own Halo profile, shown live in the app beside the chat) and get the page back as browser_read does. Use it for what needs a real browser: signed-in pages, JavaScript apps, forms and multi-step tasks. To just read an article, read_web_page is quicker.",
        parameters: [
            "type": "object",
            "properties": ["url": ["type": "string", "description": "The address to open."]],
            "required": ["url"],
        ]
    )

    static let browserRead = ToolSpec.function(
        name: ToolName.browserRead.rawValue,
        description: "Read the page open in Chrome: its address, title, text, and its interactive elements numbered [n] for browser_click and browser_type. The numbers change whenever the page is read, so read again after the page changes.",
        parameters: ["type": "object", "properties": [:]]
    )

    static let browserClick = ToolSpec.function(
        name: ToolName.browserClick.rawValue,
        description: "Click an element in Chrome by its [n] id from the latest read. The user approves every click first and sees the element outlined, so say briefly what you're clicking and why. Returns the page afterwards.",
        parameters: [
            "type": "object",
            "properties": ["element_id": ["type": "integer", "description": "The element's [n] from the latest read."]],
            "required": ["element_id"],
        ]
    )

    static let browserType = ToolSpec.function(
        name: ToolName.browserType.rawValue,
        description: "Type text in Chrome: into a field by its [n] id (it's clicked and its current text replaced), or wherever the cursor is. The user approves first. Never type passwords, card numbers or other secrets; ask the user to type those in the browser panel themselves. Returns the page afterwards.",
        parameters: [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "element_id": ["type": "integer", "description": "The field's [n] from the latest read. Leave out to type where the cursor is."],
                "submit": ["type": "boolean", "description": "Press Enter afterwards (default false)."],
            ],
            "required": ["text"],
        ]
    )

    static let browserPress = ToolSpec.function(
        name: ToolName.browserPress.rawValue,
        description: "Press a key in Chrome, like Enter to submit or Escape to close a popup. The user approves first. Returns the page afterwards.",
        parameters: [
            "type": "object",
            "properties": ["key": ["type": "string", "enum": ["Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End", "Space"]]],
            "required": ["key"],
        ]
    )

    static let browserScroll = ToolSpec.function(
        name: ToolName.browserScroll.rawValue,
        description: "Scroll the page in Chrome to see more of it, then get the page back as browser_read does.",
        parameters: [
            "type": "object",
            "properties": [
                "direction": ["type": "string", "enum": ["down", "up"]],
                "pages": ["type": "number", "description": "How far, in screens (default 1)."],
            ],
            "required": ["direction"],
        ]
    )

    /// The image, video and voice models the user picked in Settings, so the media tools can say
    /// what those models actually accept. Changes only when the user picks another model, so the
    /// tool list stays the same from request to request (and cached).
    struct MediaModels {
        var image: ImageModelInfo?
        var imageName = "the user's image model"
        var video: VideoModelInfo?
        var videoName = "the user's video model"
        var speech: ORModel?
        var speechName = "the user's voice model"
        var defaultVoice = ""
    }

    private static let defaultImageShapes = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9"]

    static func generateImage(_ media: MediaModels) -> ToolSpec {
        let info = media.image
        let offered = (info?.aspectRatios ?? []).filter { $0 != "auto" }
        let shapes = offered.isEmpty ? defaultImageShapes : defaultImageShapes.filter(offered.contains) + offered.filter { !defaultImageShapes.contains($0) }
        var model: [String] = []
        if let info {
            if info.requiresReferences {
                model.append("it only edits, so it needs at least one reference image")
            } else if info.supportsReferences {
                let most = Int(info.supportedParameters?["input_references"]?.max ?? 1)
                model.append("it makes new images and edits (up to \(most) reference image\(most == 1 ? "" : "s"))")
            } else {
                model.append("it makes new images from text only and can't take reference images; for an edit, tell the user to pick an editing model in the card")
            }
            if info.supportsTransparency { model.append("it can make transparent backgrounds") }
            if info.makesVectors { model.append("it draws vector (SVG) art") }
        }
        let modelLine = model.isEmpty ? "" : " Current model, \(media.imageName): " + model.joined(separator: "; ") + "."
        return .function(
            name: ToolName.generateImage.rawValue,
            description: """
            Make or edit images with the user's image model. Use it when the user wants a picture, illustration, logo, poster, mockup or a change to a photo. Each request shows the user a card where they can change the prompt, model and settings before approving, and each image costs money, so send one request per idea.\(modelLine)
            Writing the prompt: image models now follow plain descriptive sentences far better than keyword lists.
            - A new image: the subject and what it's doing, the setting, composition and framing, lighting, style or medium (photo, watercolor, 3D render, flat vector…) and mood. For a realistic photo, describe it as a photograph (camera angle, lens, time of day, light) rather than adding filler like "realistic, 8k, masterpiece".
            - Words in the image: put the exact text in quotes and say where it goes and how it looks.
            - An edit (reference_image_ids): say what to change, then what must stay exactly as it is: the subject's identity, pose and proportions, composition, camera angle, background and lighting. Don't re-describe the whole picture. With several references, name them by order: "the first image", "the second image".
            - Keep to what the user asked for: add detail that makes it vivid, not elements they didn't ask for.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "The full prompt for a new image, or the edit instructions (what changes, what stays) when reference images are given."],
                    "aspect_ratio": ["type": "string", "enum": .array(shapes.map { .string($0) }), "description": "The image's shape. Default 1:1."],
                    "count": ["type": "integer", "minimum": 1, "maximum": 4, "description": "How many images (default 1). More than one only when the user wants options to choose from."],
                    "transparent_background": ["type": "boolean", "description": "A cut-out with no background, for logos, icons and stickers. Only some models can; the user can change it."],
                    "reference_image_ids": ["type": "array", "items": ["type": "string"], "description": "Ids (img_ab12cd) of attached or earlier generated images to edit or use as a reference. Always pass the user's image when they ask to change it."],
                ],
                "required": ["prompt"],
            ]
        )
    }

    static func generateVideo(_ media: MediaModels) -> ToolSpec {
        let info = media.video
        let durations = (info?.supportedDurations ?? []).sorted()
        let shapes = (info?.supportedAspectRatios ?? []).isEmpty ? ["16:9", "9:16", "1:1"] : info!.supportedAspectRatios!
        var model: [String] = []
        if let info {
            if !durations.isEmpty { model.append("lengths of " + durations.map(String.init).joined(separator: ", ") + " seconds") }
            model.append(info.generateAudio == true ? "it makes sound (dialogue, effects, music) with the picture" : "it makes silent clips")
            model.append(info.supportsFirstFrame ? "it can start from an image" : "it can't start from an image")
        }
        let modelLine = model.isEmpty ? "" : " Current model, \(media.videoName): " + model.joined(separator: "; ") + "."
        let sound = info?.generateAudio == false ? "" : "\n- Sound: dialogue in quotes with who says it, then ambient sound and music."
        return .function(
            name: ToolName.generateVideo.rawValue,
            description: """
            Make a short video clip with the user's video model. It's slow (1 to 5 minutes) and one of the most expensive things Halo does, so use it only when the user clearly asks for a video. The user approves each one in a card and can change the settings.\(modelLine)
            Write the prompt as one continuous shot, in plain sentences:
            - The subject and setting, then the action as it unfolds: one or two clear beats fit in a few seconds.
            - The camera: shot size and movement (static, slow push in, tracking, handheld, aerial).
            - The look: lighting, time of day, style (live action, anime, claymation…) and mood.\(sound)
            - From an image (first_frame_image_id): the image is the first frame, so describe the motion and camera from there and don't contradict what's in it.
            - No on-screen text and no cuts: a clip is one shot.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": .string("The shot: subject, action, camera, look\(info?.generateAudio == false ? "" : " and sound").")],
                    "duration_seconds": ["type": "integer", "minimum": .number(Double(durations.first ?? 2)), "maximum": .number(Double(durations.last ?? 15)),
                                         "description": .string(durations.isEmpty ? "Clip length in seconds (default 6)." : "Clip length in seconds: \(durations.map(String.init).joined(separator: ", ")); others snap to the nearest. Default 6.")],
                    "aspect_ratio": ["type": "string", "enum": .array(shapes.map { .string($0) }), "description": "Default 16:9."],
                    "first_frame_image_id": ["type": "string", "description": "An image id (img_ab12cd) to animate, when the user wants their picture brought to life."],
                ],
                "required": ["prompt"],
            ]
        )
    }

    static func generateSpeech(_ media: MediaModels) -> ToolSpec {
        let voices = media.speech?.supportedVoices ?? []
        let voiceInfo: String
        if media.speech != nil && voices.isEmpty {
            voiceInfo = "This model has one voice of its own; leave voice out."
        } else if voices.isEmpty {
            voiceInfo = "Leave it out for the user's default voice."
        } else {
            let shown = voices.prefix(40).joined(separator: ", ")
            let more = voices.count > 40 ? " (and \(voices.count - 40) more)" : ""
            let fallback = media.defaultVoice.isEmpty ? "" : " (\(media.defaultVoice))"
            voiceInfo = "One of: \(shown)\(more). Leave it out for the user's default voice\(fallback), and pick another only when the user asks or the text calls for it."
        }
        return .function(
            name: ToolName.generateSpeech.rawValue,
            description: """
            Speak text aloud with the user's voice model (currently \(media.speechName)) and show it as an audio player. Use it when the user wants to hear something: read aloud, narrate, pronounce, a voiceover or a sound clip. It costs money, so not for ordinary replies.
            The text is read exactly as written, so write it for the ear: no Markdown, lists, emoji, links or code; spell out what should be said aloud (abbreviations, symbols, tricky numbers or dates); use punctuation for pauses and pace.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Exactly what is spoken, written to be heard."],
                    "voice": ["type": "string", "description": .string(voiceInfo)],
                    "style_instructions": ["type": "string", "description": "How to say it, in a short phrase: tone, pace, accent or character, e.g. 'warm and unhurried' or 'excited sports commentator'. Some voice models follow it and others ignore it, so the text itself should carry the meaning."],
                ],
                "required": ["text"],
            ]
        )
    }

    #if os(macOS)
    static let runCommand = ToolSpec.function(
        name: ToolName.runCommand.rawValue,
        description: "Run a command in a real zsh shell on the user's Mac, with the user's own permissions and installed programs (python3, git, ffmpeg, sqlite3…). Every command waits for the user's approval first, so do a whole task in one well-formed command rather than many small ones. The working directory is the chat's workspace, which contains the chat's attached files under their file names; write new files there too. stdin is closed, so no interactive programs — pipe a command what it needs. The command ends when the shell exits; to leave something running (a local server), background it with its output in a file: nohup cmd > log.txt 2>&1 &. Long output is cut at 16,000 characters, so narrow it with grep, head or jq. For plain web API calls, shell (curl into jq) needs no approval and is quicker.",
        parameters: [
            "type": "object",
            "properties": ["command": ["type": "string", "description": "The shell command to run."]],
            "required": ["command"],
        ]
    )
    #endif

    static let runCode = ToolSpec.function(
        name: ToolName.runCode.rawValue,
        description: "Execute code on the user's device and get stdout/result back. Python runs in Pyodide (numpy, pandas, openpyxl, pyarrow, matplotlib, sympy, scipy load on demand; no network, no input()); matplotlib figures are shown to the user automatically. JavaScript runs in a sandbox without DOM or network. Files the user attached in this chat are mounted at /attachments/<file name>, so load and analyze them there (pandas.read_csv, openpyxl for .xlsx, plain open for text). Use it for any calculation beyond one simple step (unit conversions, multi-step math, large or precise numbers, dates, statistics) instead of working it out in your head, and quote results from its output. Also for data analysis, charts and checking code.",
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

    #if os(macOS)
    private static let deviceInfoDescription = "The user's Mac right now: Low Power Mode, free storage, macOS version, Mac model, language and region, time zone and the exact local time."
    private static let tapVerb = "clicks"
    #else
    private static let deviceInfoDescription = "The user's iPhone right now: battery level and charging state, Low Power Mode, free storage, iOS version, device model, language and region, time zone and the exact local time."
    private static let tapVerb = "taps"
    #endif

    static let deviceInfo = ToolSpec.function(
        name: ToolName.deviceInfo.rawValue,
        description: deviceInfoDescription,
        parameters: ["type": "object", "properties": [:]]
    )

    static let openInApp = ToolSpec.function(
        name: ToolName.openInApp.rawValue,
        description: "Show a button that opens another app: Maps (a search or address), Safari (a URL or web search), Music (a search) or Shortcuts (run a shortcut by name). The user \(tapVerb) it; nothing opens by itself.",
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
