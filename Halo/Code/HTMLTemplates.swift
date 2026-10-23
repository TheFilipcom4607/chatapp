import Foundation

enum HTMLTemplates {
    static let pyodideHost = """
    <!doctype html><html><head><meta charset="utf-8">
    <script src="https://cdn.jsdelivr.net/pyodide/v0.27.7/full/pyodide.js"></script>
    </head><body><script>
    let out = [], err = [];
    const ready = (async () => {
      const py = await loadPyodide();
      py.setStdout({ batched: (s) => out.push(s) });
      py.setStderr({ batched: (s) => err.push(s) });
      window.pyodide = py;
      return py;
    })();
    window.haloRunPython = async function(code) {
      let result = null, error = null, images = [];
      out = []; err = [];
      try {
        const py = await ready;
        await py.loadPackagesFromImports(code);
        const usesPlot = /matplotlib|seaborn|plt\\./.test(code);
        if (usesPlot) {
          await py.loadPackage('matplotlib');
          await py.runPythonAsync("import matplotlib\\nmatplotlib.use('AGG')\\nimport matplotlib.pyplot as plt\\nplt.style.use('dark_background')\\nplt.rcParams['figure.facecolor']='#111114'\\nplt.rcParams['axes.facecolor']='#111114'\\nplt.rcParams['savefig.facecolor']='#111114'");
        }
        const r = await py.runPythonAsync(code);
        if (r !== undefined && r !== null) { result = String(r); if (r.destroy) r.destroy(); }
        if (usesPlot) {
          const imgs = await py.runPythonAsync(`
    import sys, io, base64
    _halo_imgs = []
    if 'matplotlib.pyplot' in sys.modules:
        import matplotlib.pyplot as _plt
        for _n in _plt.get_fignums():
            _b = io.BytesIO()
            _plt.figure(_n).savefig(_b, format='png', dpi=160, bbox_inches='tight')
            _halo_imgs.append(base64.b64encode(_b.getvalue()).decode())
        _plt.close('all')
    _halo_imgs
    `);
          images = imgs.toJs();
          imgs.destroy();
        }
      } catch (e) { error = String(e && e.message ? e.message : e); }
      return JSON.stringify({ stdout: out.join('\\n'), stderr: err.join('\\n'), result, error, images });
    };
    </script></body></html>
    """

    static func page(kind: ArtifactKind, content: String) -> String {
        switch kind {
        case .html: return html(content)
        case .react: return react(content)
        case .svg: return svg(content)
        case .mermaid: return mermaid(content)
        case .markdown, .code: return "<pre>\(escape(content))</pre>"
        }
    }

    /// Picks a template for a fenced code block's language.
    static func page(language: String, code: String) -> String {
        switch language.lowercased() {
        case "svg": return svg(code)
        case "jsx", "tsx", "react": return react(code)
        case "mermaid": return mermaid(code)
        default: return html(code)
        }
    }

    static func html(_ content: String) -> String {
        let lower = content.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            if lower.contains("name=\"viewport\"") { return content }
            return content.replacingOccurrences(of: "<head>", with: "<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">", options: .caseInsensitive)
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,system-ui;margin:16px}</style></head><body>
        \(content)
        </body></html>
        """
    }

    static func svg(_ content: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#fff;display:flex;align-items:center;justify-content:center}svg{max-width:100%;max-height:100vh;height:auto}</style>
        </head><body>\(content)</body></html>
        """
    }

    static func mermaid(_ content: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script>
        <style>body{margin:0;padding:16px;background:#0b0b0f;color:#eee;font-family:-apple-system}.mermaid{display:flex;justify-content:center}</style>
        </head><body><pre class="mermaid">\(escape(content))</pre>
        <script>mermaid.initialize({ startOnLoad: true, theme: 'dark', securityLevel: 'loose' });</script>
        </body></html>
        """
    }

    static func react(_ source: String) -> String {
        let prepared = ReactSourceTransformer.transform(source)
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.tailwindcss.com/3.4.17"></script>
        <script crossorigin src="https://unpkg.com/react@18.3.1/umd/react.production.min.js"></script>
        <script crossorigin src="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js"></script>
        <script crossorigin src="https://unpkg.com/prop-types@15.8.1/prop-types.min.js"></script>
        <script crossorigin src="https://unpkg.com/lucide-react@0.468.0/dist/umd/lucide-react.min.js"></script>
        <script crossorigin src="https://unpkg.com/recharts@2.15.0/umd/Recharts.min.js"></script>
        <script src="https://unpkg.com/@babel/standalone@7.26.4/babel.min.js"></script>
        <style>body{margin:0;font-family:-apple-system,system-ui}#__err{color:#f87171;font:13px ui-monospace,monospace;white-space:pre-wrap;padding:16px}</style>
        </head><body><div id="root"></div><div id="__err"></div>
        <script>window.onerror = (m, s, l, c, e) => { document.getElementById('__err').textContent = String(e || m); };</script>
        <script type="text/babel" data-presets="react">
        \(prepared)
        </script></body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Rewrites a single-file React component (ES module style) so it runs with UMD globals.
enum ReactSourceTransformer {
    static let hooks = ["useState", "useEffect", "useRef", "useMemo", "useCallback", "useReducer", "useContext",
                        "createContext", "Fragment", "useLayoutEffect", "useId", "forwardRef", "memo", "useTransition", "useDeferredValue"]
    static let globals: [String: String] = ["react": "React", "react-dom": "ReactDOM", "lucide-react": "LucideReact", "recharts": "Recharts", "prop-types": "PropTypes"]

    static func transform(_ source: String) -> String {
        var lines: [String] = []
        var imported = Set<String>()
        var appName: String?
        let importRegex = try? NSRegularExpression(pattern: #"^\s*import\s+(.+?)\s+from\s+['"]([^'"]+)['"];?\s*$"#)
        let bareImport = try? NSRegularExpression(pattern: #"^\s*import\s+['"][^'"]+['"];?\s*$"#)

        for line in source.components(separatedBy: "\n") {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if bareImport?.firstMatch(in: line, range: full) != nil { continue }
            if let m = importRegex?.firstMatch(in: line, range: full) {
                let clause = ns.substring(with: m.range(at: 1))
                let module = ns.substring(with: m.range(at: 2))
                let global = globals[module] ?? globals[module.components(separatedBy: "/").first ?? ""]
                var defaultName: String?
                var named: String?
                if let brace = clause.firstIndex(of: "{"), let close = clause.lastIndex(of: "}") {
                    named = String(clause[clause.index(after: brace)..<close])
                    let before = clause[..<brace].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                    if !before.isEmpty { defaultName = before }
                } else if clause.hasPrefix("* as ") {
                    defaultName = String(clause.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else {
                    defaultName = clause.trimmingCharacters(in: .whitespaces)
                }
                guard let global else {
                    lines.append("// (unavailable import removed: \(module))")
                    continue
                }
                if let d = defaultName, d != global { lines.append("const \(d) = \(global);") }
                if let named {
                    let names = named.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let mapped = names.map { $0.replacingOccurrences(of: " as ", with: ": ") }
                    names.forEach { imported.insert($0.components(separatedBy: " as ").last ?? $0) }
                    lines.append("const { \(mapped.joined(separator: ", ")) } = \(global);")
                }
                continue
            }
            var l = line
            if let r = l.range(of: #"export\s+default\s+function\s+([A-Za-z0-9_]+)"#, options: .regularExpression) {
                let decl = String(l[r])
                appName = decl.components(separatedBy: .whitespaces).last
                l.replaceSubrange(r, with: "function \(appName ?? "App")")
            } else if let r = l.range(of: #"export\s+default\s+([A-Za-z0-9_]+)\s*;?\s*$"#, options: .regularExpression) {
                appName = String(l[r]).replacingOccurrences(of: "export", with: "").replacingOccurrences(of: "default", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
                l.replaceSubrange(r, with: "")
            } else if l.range(of: #"export\s+default\s+"#, options: .regularExpression) != nil {
                l = l.replacingOccurrences(of: #"export\s+default\s+"#, with: "const __HaloApp = ", options: .regularExpression)
                appName = "__HaloApp"
            }
            l = l.replacingOccurrences(of: #"^(\s*)export\s+(const|function|class|let)"#, with: "$1$2", options: .regularExpression)
            lines.append(l)
        }
        let body = lines.joined(separator: "\n")
        let preamble = hooks.filter { !imported.contains($0) && body.contains($0) && !body.contains("const \($0)") }
            .map { "const \($0) = React.\($0);" }
            .joined(separator: "\n")
        if appName == nil {
            for candidate in ["App", "Main", "Component", "Page"] where body.contains("function \(candidate)") || body.contains("const \(candidate)") {
                appName = candidate
                break
            }
        }
        let mount = "ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(\(appName ?? "App")));"
        return preamble + "\n" + body + "\n" + mount
    }
}
