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
    static func run(language: String, code: String) async -> CodeRunResult {
        switch SyntaxTokenizer.normalize(language) {
        case "python": return await PythonRuntime.shared.run(code)
        case "javascript", "typescript": return await JSRunner.run(code)
        default: return CodeRunResult(error: "Unsupported language: \(language). Only Python and JavaScript can run on device.")
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

    let webView: WKWebView
    private var loaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        webView.isOpaque = false
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        super.init()
        webView.navigationDelegate = self
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
        if webView.url == nil && !webView.isLoading {
            webView.loadHTMLString(HTMLTemplates.pyodideHost, baseURL: URL(string: "https://halo.local/"))
        }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded = true
            let waiters = self.loadWaiters
            self.loadWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiters = self.loadWaiters
            self.loadWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiters = self.loadWaiters
            self.loadWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    func warmUp() {
        Task { await ensureLoaded() }
    }

    func run(_ code: String) async -> CodeRunResult {
        let start = Date()
        await ensureLoaded()
        guard loaded else { return CodeRunResult(error: "Couldn't load the Python runtime. Check your connection.") }
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
