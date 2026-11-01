# Provider routing: intuitive + user-controllable

## Context
Commit `ea9425f` added a "Provider" picker (Balanced / Cheapest / Fastest / Best quality / OpenRouter default) in Settings → Speed and price. It sends an OpenRouter `provider` object per request. Problems: one opaque picker + a wall of footer text, no way to see what it will actually pick, no way to set your own rules (max price, block a host, pin a host per model). Goal: a dedicated screen where presets are just starting points for visible, editable rules, plus a live preview of how a real model's providers get ranked.

Implementer: another model with no context of this chat. Everything needed is below. Swift/SwiftUI iOS app, Xcode project `Halo.xcodeproj`, scheme `Halo`. Match surrounding code style (short doc comments, `@Observable AppSettings`, `MenuPickerRow`).

## Bug found (why Balanced routed GLM 5.3 Flash to Together at $0.15/$0.50)
The parameter names are correct per the docs (`sort`, `preferred_min_throughput`/`preferred_max_latency` = soft, number = p50 over a rolling 5-min window, `max_price` $/M, `quantizations` hard). The cheapest host Balanced allows is Relace ($0.038/$0.074, quant "unknown", ~64 tok/s, ~1.1s), and it should have been picked. The real cause: `RequestBuilder.swift:129` sends `session_id = conversation.id`. Per OpenRouter's prompt-caching docs, a `session_id` turns on **sticky routing after any successful request** (10 min idle expiry), and **only `provider.order` overrides it**. `sort` does not. So a chat stays on whatever host first answered it.
**Fix (core of this plan):** Halo ranks the providers itself (Step 3) and sends the result as `provider.order` plus `allow_fallbacks`, keeping the soft thresholds and hard filters as a backstop. This beats sticky routing, and the preview then shows exactly what gets sent. The trade-off is losing cache stickiness, so add a rule "Stay on one host per chat (better caching)", default **off**. When it's on, put the provider that served the chat's last assistant message (`Message.provider`) first in `order`, as long as it still passes the hard filters. Cap `order` at ~8 slugs (use endpoint `tag`s like `relace`, `z-ai/fp8`; OpenRouter accepts tags in `order`).
Data for ranking comes from `/endpoints`. Step 0 must confirm it has throughput/latency stats. If it doesn't, rank by price among hosts that pass precision/price filters, and leave the speed preference to OpenRouter's soft thresholds.

## What exists now (read these first)
- `Halo/Chat/ServiceTier.swift` (bottom): `enum ProviderRouting` with `preferences(quants:) -> JSONValue?`, `minThroughput=40`, `maxLatency=3`, `goodQuants`, `fullQuants`. Rule: a quant filter is only sent if ≥1 of the model's providers passes it and it actually removes something.
- `Halo/OpenRouter/ChatTypes.swift`: `ChatRequest.provider: JSONValue?` (encoded as `provider`).
- `Halo/Chat/RequestBuilder.swift` ~line 93: sets `request.provider` from `settings.providerRouting` + `catalog.quantizations[modelID]`.
- `Halo/Services/AppSettings.swift`: `providerRouting: String` (UserDefaults key `providerRouting`).
- `Halo/OpenRouter/APITypes.swift`: `ModelEndpoints` (decodes `/models/{id}/endpoints`): `Endpoint{pricing, serviceTier, quantization}`, `tierPrices`, `quantizations`.
- `Halo/Services/ModelCatalog.swift`: `loadTiers(_:)` fetches endpoints (≤ every 12h), stores `tierPrices`, `quantizations`; disk cache `tiers-v1.json` via `TierCacheEntry{date, prices, quants?}`.
- `Halo/Features/Settings/SettingsView.swift` ~line 128: section "Speed and price" with "Default tier" + "Provider" `MenuPickerRow`s and a long footer. Sub-screens pattern: `SearchSettingsView.swift`, `ToolsSettingsView.swift`.
- `Halo/Features/Models/ModelPicker.swift` `modelItem`: shows cheapest standard price from `catalog.tiers(id)?[.standard]`.
- `Halo/Features/Chat/MessageDetailsView.swift:18`: already shows the provider that served a reply.
- `JSONValue` enum: `Halo/OpenRouter/JSONValue.swift` (`.null/.bool/.number/.string/.array/.object`).

## Step 0 — verify the API before coding (curl, no key needed)
```
curl -s https://openrouter.ai/api/v1/models/z-ai/glm-5.3-flash/endpoints | python3 -m json.tool | head -80
```
Check which per-endpoint fields exist: `provider_name`, `tag`, `quantization`, `uptime_last_30m`, and especially latency/throughput stats (likely `latency_last_30m` / `throughput_last_30m`, possibly percentile objects `{p50,…}`). Decode whatever exists, all optional. Also confirm in OpenRouter docs (https://openrouter.ai/docs/features/provider-routing) the exact names/shapes of: `sort`, `preferred_min_throughput`, `preferred_max_latency`, `quantizations`, `max_price` ({prompt, completion} USD per **million** tokens), `ignore`, `order`, `only`, `allow_fallbacks`, `data_collection` ("deny"), `zdr`. Fix the names in code if they differ (the current `preferred_*` names were written from memory).

## Step 1 — data model: `RoutingRules` (replace `ProviderRouting`)
New file `Halo/Chat/RoutingRules.swift` (check whether the project uses synchronized folders; if not, add the file to the Halo target in project.pbxproj — or put it in `ServiceTier.swift` to avoid that).
```swift
struct RoutingRules: Codable, Hashable, Sendable {
    enum Sort: String, Codable, CaseIterable { case price, throughput, latency, none }
    enum Precision: String, Codable, CaseIterable { case any, eightBit, full }   // any / ≥8-bit (int8,fp8,fp16,bf16,fp32,unknown) / ≥16-bit
    var sort: Sort = .price
    var minThroughput: Double? = 40      // tok/s, soft (pushed to back, not excluded)
    var maxLatency: Double? = 3          // s to first token, soft
    var precision: Precision = .eightBit // hard filter (safe-guarded, see below)
    var maxPrompt: Double? = nil         // $/M, hard
    var maxCompletion: Double? = nil     // $/M, hard
    var allowFallbacks = true
    var denyDataCollection = false
    var blocked: [String] = []           // provider slugs, global
}
enum RoutingPreset: String, CaseIterable { case balanced, cheapest, fastest, quality, openRouter }
// preset.rules -> RoutingRules; RoutingRules.matchingPreset -> RoutingPreset? (nil = "Custom")
```
Presets: balanced = defaults above; cheapest = sort price, no thresholds, precision any; fastest = sort throughput, no thresholds, eightBit; quality = balanced but `.full`; openRouter = special (send nothing except `blocked`/data policy if set).
Per-model overrides: `struct ModelRouting: Codable { var pinned: [String] = []; var blocked: [String] = [] }` stored as `[modelID: ModelRouting]`.

`AppSettings`: replace `providerRouting: String` with `routingRules: RoutingRules` + `modelRouting: [String: ModelRouting]`, persisted as JSON Data (keys `routingRules`, `modelRouting`). Migration: if old `providerRouting` string exists, map to that preset's rules once.

`func preferences(for modelID:, endpoints: [EndpointInfo]?) -> JSONValue?` builds the `provider` object:
- `sort` (omit for `.none`), `preferred_min_throughput`, `preferred_max_latency`, `allow_fallbacks`, `data_collection: "deny"` when on.
- `ignore` = global blocked + model blocked; `order` = model pinned (pinned wins over blocked), then (sticky toggle) last provider, then `rank(...)` picks. Send `order` whenever endpoints are known, even with no pins. This is what defeats sticky routing.
- Add `var stickyPerChat = false` to `RoutingRules`; `preferences` takes `lastProvider: String?` (the slug of the chat's last reply's provider). Map `Message.provider` (a display name) to a slug via the endpoints list.
- `quantizations` and `max_price`: **safety rule kept** — when endpoints are known, only send a hard filter if ≥1 non-blocked provider passes all hard filters together; if none pass, drop the price filter first, then precision, and the preview shows a warning. When endpoints are unknown, send precision filter only if it's `.any`-safe (i.e. don't send), send `max_price` as-is.
- Return nil if the object ends up empty.

## Step 2 — richer endpoint info in the catalog
- `ModelEndpoints.Endpoint`: add `providerName`, `tag`, `uptime`, `throughput`, `latency` (all optional, shape per Step 0). Slug = `tag` before the first `/` (fallback: lowercased providerName without spaces).
- New `struct EndpointInfo: Codable, Hashable { slug, name, tier, prompt, completion ($/M), quant, tps?, latency?, uptime? }`.
- `ModelCatalog`: replace `quantizations` with `endpoints: [String: [EndpointInfo]]` filled in `loadTiers`; bump cache to `tiers-v2.json` (store endpoints; keep tierPrices derivable). `quantizations` usages become `endpoints[id]?.map(\.quant)`.
- `knownProviders: [String: String]` (slug → name) = union across all cached models, for the global block list.

## Step 3 — local ranking (used for the request's `order` AND the preview)
`static func rank(_ eps: [EndpointInfo], rules:, model: ModelRouting?) -> [(EndpointInfo, Status)]` where `Status` = `.pick(Int)` or `.skipped(reason: "blocked" / "4-bit" / "over max price" / "other tier")`. Order: pinned first in pin order; then those meeting soft thresholds sorted by sort key; then those missing thresholds (label "slow"). Only standard-tier endpoints (or the chat's tier). Unit-test it.

## Step 4 — UI
1. **SettingsView** "Speed and price": keep "Default tier"; replace the Provider `MenuPickerRow` with a `NavigationLink` "Provider routing" whose value shows the preset name or "Custom". Shorten the footer back to the tier text only.
2. **New `Halo/Features/Settings/RoutingSettingsView.swift`**, sections top to bottom:
   - **Preset**: 5 rows (checkmark style), each with a one-line subtitle in plain words:
     Balanced "Cheapest host that's fast and not dumbed down" · Cheapest "Lowest price, whatever the speed" · Fastest "Highest tok/s, whatever the price" · Best quality "Full precision only, then cheapest fast" · OpenRouter default "Let OpenRouter balance it". If rules match none → a "Custom" row is checked. Tapping a preset overwrites rules (keep `blocked`).
   - **Rules** (editing any switches to Custom automatically, since preset is derived):
     - Pick by: Picker Price / Speed / Response time / OpenRouter.
     - Prefer at least: Picker Off/20/40/60/100 tok/s. Footer-free; row subtitle "Slower hosts are only used if nothing faster works".
     - Prefer first token under: Off/1/2/3/5 s.
     - Precision: Any / 8-bit or better / Full only. Subtitle "Lower bits are cheaper but noticeably dumber".
     - Max price: two optional fields $/M in & out (TextField with decimal pad, empty = no limit).
     - Toggles: "Fall back to other hosts if one fails", "Skip hosts that log or train on prompts".
   - **Blocked providers**: list from `catalog.knownProviders`, toggle each (searchable if long).
   - **Preview**: model row (defaults to `settings.defaultModelID`, tappable to choose from favorites) → a table of its providers: name, $in/$out, tok/s, s, precision, uptime; badges "1st/2nd/3rd…" or grey "skipped: 4-bit". Live-updates as rules change. Caption "Halo sends this order; if a host fails, the next one is tried." Price sort key = blended cost, e.g. prompt×3 + completion (typical chat is input-heavy); document the weight in a comment. Warning row if hard filters would exclude everyone ("No provider fits — price limit ignored for this model").
   - Swipe/tap on a preview provider: "Always use for this model" (pin) / "Never use for this model" (block) / "Block everywhere". Pinned/blocked show an icon. A "Per-model rules" section lists models with overrides, with reset.
3. **ModelPicker** (`modelItem`): optional, small — if the model has a pin, show "· via DeepInfra"; else unchanged (cheapest price already shown). Make the shown price the price of the preview's 1st pick (via `rank`) instead of the absolute cheapest, so it matches what you'll pay.
4. Show the serving provider under each reply's footer if not already visible (MessageDetailsView already has it; skip if the footer is crowded).

## Step 5 — tests (`HaloTests/`)
New `RoutingRulesTests.swift`: preset ↔ rules round trip; `preferences` JSON for each preset; safety rule (all endpoints fp4 → no `quantizations`; max price below all → dropped); pin → `order`, block → `ignore`; `rank` ordering incl. soft thresholds. Update any test referencing `ProviderRouting` or `quantizations`. Run:
```
xcodebuild test -project Halo.xcodeproj -scheme Halo -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -quiet
```

## Verification (no simulator available to the implementer)
1. It builds, and unit tests pass if a simulator destination exists. If none does, build the test target with `build-for-testing` and say the tests weren't run.
2. Install on the phone (below) and commit locally. Don't push.
3. Finish with a short **"Please test on your phone"** checklist for the user, for example: Settings → Provider routing opens and the presets read clearly; changing a rule switches it to Custom; GLM 5.3 Flash's preview lists Relace first under Balanced; in a **new** chat with GLM 5.3 Flash, message details show Relace (or the preview's #1); pin another host → the next reply uses it; block it → it's skipped; turning on the sticky toggle keeps a chat on one host; the model menu price matches the preview's #1.
4. Install on phone exactly as before: build with `-destination 'id=00008140-001475100CBB001C' -derivedDataPath build-device APP_BUNDLE_ID=com.filip.halo -allowProvisioningUpdates`, then `xcrun devicectl device install app --device 00008140-001475100CBB001C build-device/Build/Products/Debug-iphoneos/Halo.app`. Never uninstall the app. Commit locally, don't push.
