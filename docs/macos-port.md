# Halo on macOS

Goal: a native macOS build of Halo from the same SwiftUI code (not Catalyst, not "Designed for iPhone"). First make it build and work plainly, then add Mac-specific polish a bit at a time. The iOS app must keep building and behaving exactly as before.

## Approach
- **One multiplatform target.** The `Halo` target gets `macosx` in `SUPPORTED_PLATFORMS` and `MACOSX_DEPLOYMENT_TARGET = 26.0`. No new target, so every source file is shared by default.
- **iOS-only pieces stay iOS-only:**
  - The `HaloShare` extension is embedded and built for iOS only (platform filter). There's no Mac share extension.
  - Unit tests stay on the iOS simulator.
- **No App Sandbox on the Mac** (`Config/Halo-macOS.entitlements` is empty). The Chrome tool has to start Chrome with DevTools flags, and macOS drops the arguments of apps a sandboxed app opens. Halo keeps its files in its own folders under `~/Library/Application Support` and `~/Library/Caches` (`AppFolders`, named after the bundle id). Camera, microphone, calendar and location still ask through the usual prompts.
- **Platform code lives in a few small shims** rather than `#if` scattered everywhere:
  - `PlatformImage` (UIImage/NSImage) with the few helpers we use (PNG/JPEG data, CGImage init)
  - `Clipboard` (UIPasteboard/NSPasteboard)
  - Color bridging, plus no-op haptics on the Mac
  - View modifiers for the iOS-only SwiftUI calls (`navigationBarTitleDisplayMode`, `textInputAutocapitalization`, `keyboardType`, `topBarLeading/Trailing` placements, `fullScreenCover`). These become no-ops or Mac equivalents.

## Phase 1: it builds and works (no fancy stuff)
1. Build settings and Mac entitlements. Restrict the share extension to iOS.
2. Add the shims and switch call sites to them.
3. Fix the remaining compile errors file by file. The UIKit-heavy files are:
   - the composer text view (`UITextView`): use a plain multi-line SwiftUI `TextField` on the Mac for now
   - `SelectTextSheet`: use selectable `Text` on the Mac
   - camera picker (`UIImagePickerController`): hidden on the Mac, and photo/file pickers still work
   - share sheet (`UIActivityViewController`): `ShareLink` / `NSSharingServicePicker`
   - saving to Photos (`UIImageWriteToSavedPhotosAlbum`): a save panel / Downloads
   - `AVAudioSession` (read-aloud, dictation): not needed on the Mac
   - the app-lock window (`UIWindowScene`): use an overlay on the Mac
   - the sidebar swipe gesture (`UIPanGestureRecognizer`): use a button and a SwiftUI drag on the Mac
   - background tasks (`UIBackgroundTaskIdentifier`): not needed on the Mac
4. Launch it. Sign in, chat with streaming, use tools (search, code, images), artifacts, settings and the spend page. Fix whatever is broken or looks wrong in a resizable window.
5. Check that iOS still builds and the iOS tests still pass.

## Phase 2: Mac polish (only some of it, one at a time)
- A permanent sidebar (`NavigationSplitView`) instead of the phone's slide-in drawer.
- Keyboard: Return sends and Shift-Return adds a newline. ⌘N for a new chat, ⌘F for search.
- Settings in the standard Mac Settings window (⌘,).
- Paste and drag-and-drop images or files into the composer.
- A sensible default window size and minimum size.

## Status (2026-11-01)
- **Phase 1: done.** The Mac build compiles, signs and runs. The iOS build and all 168 unit tests still pass.
  - Shims live in `Halo/Design/Platform.swift`.
  - On the Mac, sheets get a window-sized frame (`sheetFrame()`), and forms, buttons and menus get iOS-like styles (`platformDefaults()`).
  - Saving an image goes to Downloads instead of Photos. Camera and haptics are iOS-only.
- **Phase 2: in progress.**
  - The sidebar sits beside the chat and stays open (toggled with the `sidebar.left` button).
  - The composer is an `NSTextView`: Return sends, Shift-Return adds a line, and pasted or dropped images and files attach.
  - Menu commands: ⌘N new chat, ⌘F search chats, ⌘, settings, ⌃⌘S show/hide sidebar. Window tabbing is off.
  - Snapshots also fire on `kill -USR1 <pid>`, so a menu item driven through System Events can be checked.
  - Escape closes any sheet. Text fields are plain, and switch and date rows spread across their row as on iOS.
  - Checked on the Mac: Python (Pyodide 3.12.7 + numpy) and JavaScript runs work. Demo screens `run`, `runjs` and `device` run them on launch.
- **Compare (Mac):**
  - Composer → Compare picks up to 3 more models.
  - One message goes to all of them at once. Their replies stream side by side as sibling branches, sent without tools.
  - "Continue with this" carries on with that reply and its model. The others stay as ‹ 1/3 › branches.
  - Demo screen: `compare`.
- **Chrome (Mac):**
  - Real Chrome runs headless under its own profile (`~/Library/Application Support/Halo/Chrome`), driven over DevTools on port 9333 (`Halo/Browser/`).
  - The tab streams live into a panel beside the chat (⌥⌘B), sized to the panel at 2×. The user can click, scroll and type in it.
  - Tools: `browser_open`, `browser_read` and `browser_scroll` run freely. `browser_click`, `browser_type` and `browser_press` wait in an approval popup, with the target outlined in the page.
  - Halo starts Chrome by itself, and shuts it down with SIGTERM when Halo quits (headless Chrome ignores the usual quit request). A sandboxed build would fall back to showing a one-line Terminal command in the panel.
  - Demo screens: `browser`, `browserallow`.
  - Mac demo runs use an in-memory store, so they never touch real chats.
- **Reviewing the UI without screen access:** launch the Debug build with `-demo -demoScreen <screen> -snapshot [seconds]`. It writes `snapshot.png` (plus `snapshot-sheet.png` when a sheet is open) to the user's temp folder (`getconf DARWIN_USER_TEMP_DIR`). It works with the screen locked, but Liquid Glass backgrounds don't show up in these images.
- **Not checked yet:**
  - signing in, and live streaming against the real API
  - dictation, Touch ID lock and OAuth on the Mac
  - glass rendering in the real window

## Not doing
Share extension, widgets, haptics, a menu bar extra, multiple chat windows, Catalyst, and Mac App Store packaging.
