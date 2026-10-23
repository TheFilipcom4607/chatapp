import Foundation
import JavaScriptCore
import WebKit
import UIKit

struct CodeRunResult: Sendable {
    var stdout: String = ""
    var stderr: String = ""
    var result: String?
    var error: String?
    var images: [Data] = []
    var duration: TimeInterval = 0

    /// Compact text given back to the model.
    var modelSummary: String {
        var parts: [String] = []
        if !stdout.isEmpty { parts.append("stdout:\n" + String(stdout.prefix(8000))) }
        if !stderr.isEmpty { parts.append("stderr:\n" + String(stderr.prefix(3000))) }
        if let result, !result.isEmpty, result != "undefined", result != "None" { parts.append("result: " + String(result.prefix(3000))) }
        if let error { parts.append("error:\n" + String(error.prefix(3000))) }
        if !images.isEmpty { parts.append("\(images.count) figure(s) were rendered and shown to the user.") }
        if parts.isEmpty { parts.append("(no output)") }
        return parts.joined(separator: "\n\n")
    }

    /// Text shown in the console card.
    var consoleText: String {
        var parts: [String] = []
        if !stdout.isEmpty { parts.append(stdout) }
        if !stderr.isEmpty { parts.append(stderr) }
        if let result, !result.isEmpty, result != "undefined", result != "None" { parts.append("→ " + result) }
        if let error { parts.append("✕ " + error) }
        return parts.isEmpty ? "(no output)" : parts.joined(separator: "\n")
    }
}

enum CodeRunner {
    static let javascriptTimeLimit: TimeInterval = 30
    static let pythonTimeLimit: TimeInterval = 300   // includes downloading Pyodide and packages on first use

    static func run(language: String, code: String) async -> CodeRunResult {
        let start = Date()
        switch SyntaxTokenizer.normalize(language) {
        case "python":
            return await PythonRuntime.shared.run(code, timeLimit: pythonTimeLimit)
        case "javascript", "typescript":
            switch await Deadline.race(seconds: javascriptTimeLimit, { await JSRunner.run(code) }) {
            case .finished(let result): return result
            case .timedOut: return CodeRunResult(error: "Stopped after \(Int(javascriptTimeLimit))s (the code may loop forever).", duration: Date().timeIntervalSince(start))
            case .cancelled: return CodeRunResult(error: "Cancelled.", duration: Date().timeIntervalSince(start))
            }
        default: return CodeRunResult(error: "Unsupported language: \(language). Only Python and JavaScript can run on device.")
        }
    }
}

/// Waits for an operation, but gives up after a time limit or when the calling task is cancelled.
/// JavaScriptCore and WebKit evaluation can't be interrupted, so the operation itself may keep
/// running; the caller just stops waiting for it.
enum Deadline {
    enum Outcome<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
        case cancelled
    }

    static func race<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> Outcome<T> {
        let gate = Gate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
                gate.install(continuation)
                Task {
                    let value = await operation()
                    gate.resolve(.finished(value))
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    gate.resolve(.timedOut)
                }
            }
        } onCancel: {
            gate.resolve(.cancelled)
        }
    }

    /// Resumes the continuation exactly once, with whichever outcome arrives first.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<T>, Never>?
        private var early: Outcome<T>?
        private var done = false

        func install(_ c: CheckedContinuation<Outcome<T>, Never>) {
            lock.lock()
            if let early {
                done = true
                lock.unlock()
                c.resume(returning: early)
                return
            }
            continuation = c
            lock.unlock()
        }

        func resolve(_ outcome: Outcome<T>) {
            lock.lock()
            guard !done, early == nil else { lock.unlock(); return }
            guard let c = continuation else {
                early = outcome   // arrived before install (e.g. already cancelled)
                lock.unlock()
                return
            }
            continuation = nil
            done = true
            lock.unlock()
            c.resume(returning: outcome)
        }
    }
}

/// Runs JavaScript in an isolated JavaScriptCore context with console capture.
enum JSRunner {
    private final class Box: @unchecked Sendable {
        var lines: [String] = []
        var errors: [String] = []
        let lock = NSLock()
        func add(_ s: String, error: Bool) { lock.lock(); if error { errors.append(s) } else { lines.append(s) }; lock.unlock() }
    }

    static func run(_ code: String) async -> CodeRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                let box = Box()
                guard let ctx = JSContext() else {
                    continuation.resume(returning: CodeRunResult(error: "JavaScript engine unavailable"))
                    return
                }
                let log: @convention(block) (String, Bool) -> Void = { text, isError in box.add(text, error: isError) }
                ctx.setObject(log, forKeyedSubscript: "__halo_log" as NSString)
                ctx.evaluateScript("""
                (function(){
                  const fmt = (a) => a.map(x => { if (typeof x === 'string') return x; try { return JSON.stringify(x, null, 2) ?? String(x); } catch (e) { return String(x); } }).join(' ');
                  globalThis.console = {
                    log: (...a) => __halo_log(fmt(a), false), info: (...a) => __halo_log(fmt(a), false),
                    debug: (...a) => __halo_log(fmt(a), false), table: (...a) => __halo_log(fmt(a), false),
                    warn: (...a) => __halo_log(fmt(a), true), error: (...a) => __halo_log(fmt(a), true)
                  };
                  globalThis.__halo_result = undefined; globalThis.__halo_error = undefined;
                })();
                """)
                var exception: String?
                ctx.exceptionHandler = { _, exc in
                    let msg = exc?.toString() ?? "Error"
                    let line = exc?.objectForKeyedSubscript("line")?.toString()
                    exception = line.map { "\(msg) (line \($0))" } ?? msg
                }
                let value = ctx.evaluateScript(code)
                var resultString: String? = nil
                if let value, !value.isUndefined {
                    // Resolve promises (microtasks drain after evaluateScript returns).
                    if value.hasProperty("then") {
                        ctx.setObject(value, forKeyedSubscript: "__halo_p" as NSString)
                        ctx.evaluateScript("__halo_p.then(r => { globalThis.__halo_result = (typeof r === 'object' ? JSON.stringify(r, null, 2) : String(r)); }, e => { globalThis.__halo_error = String(e); });")
                        let r = ctx.objectForKeyedSubscript("__halo_result")
                        if let r, !r.isUndefined { resultString = r.toString() }
                        let e = ctx.objectForKeyedSubscript("__halo_error")
                        if let e, !e.isUndefined { exception = e.toString() }
                    } else if value.isObject, let json = ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value, NSNull(), 2]), !json.isUndefined {
                        resultString = json.toString()
                    } else {
                        resultString = value.toString()
                    }
                }
                box.lock.lock()
                let result = CodeRunResult(stdout: box.lines.joined(separator: "\n"), stderr: box.errors.joined(separator: "\n"),
                                           result: resultString, error: exception, duration: Date().timeIntervalSince(start))
                box.lock.unlock()
                continuation.resume(returning: result)
            }
        }
    }
}

/// Python via Pyodide inside a hidden WKWebView (loads from CDN on first use).
@MainActor
final class PythonRuntime: NSObject, WKNavigationDelegate {
    static let shared = PythonRuntime()

    private(set) var webView: WKWebView
    private var loaded = false
    private var loading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Runs share one interpreter and its stdout buffers, so they go one at a time.
    private var running = false
    private var runWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        webView = Self.makeWebView()
        super.init()
        webView.navigationDelegate = self
    }

    private static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView.isOpaque = false
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        return webView
    }

    /// Ensures the web view is in a window (offscreen web views get throttled).
    func attachIfNeeded() {
        guard webView.window == nil,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { return }
        window.addSubview(webView)
        window.sendSubviewToBack(webView)
    }

    private func ensureLoaded() async {
        attachIfNeeded()
        if loaded { return }
        if !loading {
            // (Re)load the host page; also retries after an earlier failed load.
            loading = true
            webView.loadHTMLString(HTMLTemplates.pyodideHost, baseURL: URL(string: "https://halo.local/"))
        }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    private func finishLoading(_ webView: WKWebView, success: Bool) {
        guard webView === self.webView else { return }   // a web view replaced by reset()
        loaded = success
        loading = false
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoading(webView, success: true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading(webView, success: false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading(webView, success: false) }
    }

    /// Throws away a web view that may still be busy (runaway code) and starts fresh next time.
    private func reset() {
        let old = webView
        old.navigationDelegate = nil
        old.stopLoading()
        old.removeFromSuperview()
        webView = Self.makeWebView()
        webView.navigationDelegate = self
        loaded = false
        loading = false
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func acquire() async {
        if running {
            await withCheckedContinuation { runWaiters.append($0) }
        } else {
            running = true
        }
    }

    private func release() {
        if runWaiters.isEmpty { running = false } else { runWaiters.removeFirst().resume() }
    }

    func warmUp() {
        Task { await ensureLoaded() }
    }

    func run(_ code: String, timeLimit: TimeInterval) async -> CodeRunResult {
        await acquire()
        defer { release() }
        let start = Date()
        if Task.isCancelled { return CodeRunResult(error: "Cancelled.") }
        await ensureLoaded()
        guard loaded else { return CodeRunResult(error: "Couldn't load the Python runtime. Check your connection.") }
        let webView = self.webView
        let outcome = await Deadline.race(seconds: timeLimit) { @MainActor in
            await PythonRuntime.evaluate(code, in: webView, start: start)
        }
        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            reset()
            return CodeRunResult(error: "Stopped after \(Int(timeLimit))s (the code may loop forever).", duration: Date().timeIntervalSince(start))
        case .cancelled:
            reset()
            return CodeRunResult(error: "Cancelled.", duration: Date().timeIntervalSince(start))
        }
    }

    private static func evaluate(_ code: String, in webView: WKWebView, start: Date) async -> CodeRunResult {
        do {
            let raw = try await webView.callAsyncJavaScript("return await window.haloRunPython(code);", arguments: ["code": code], in: nil, contentWorld: .page)
            guard let json = raw as? String, let data = json.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return CodeRunResult(error: "Python returned no output.")
            }
            var r = CodeRunResult()
            r.stdout = obj["stdout"] as? String ?? ""
            r.stderr = obj["stderr"] as? String ?? ""
            r.result = obj["result"] as? String
            r.error = obj["error"] as? String
            r.images = (obj["images"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
            r.duration = Date().timeIntervalSince(start)
            return r
        } catch {
            return CodeRunResult(error: error.localizedDescription, duration: Date().timeIntervalSince(start))
        }
    }
}
