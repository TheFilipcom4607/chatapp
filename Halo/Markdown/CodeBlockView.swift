import SwiftUI

enum SyntaxTheme {
    static func color(_ kind: SyntaxTokenizer.Kind) -> Color {
        switch kind {
        case .keyword: return Color(red: 0.99, green: 0.47, blue: 0.66)
        case .string: return Color(red: 0.99, green: 0.80, blue: 0.47)
        case .comment: return Color(red: 0.50, green: 0.53, blue: 0.60)
        case .number: return Color(red: 0.73, green: 0.62, blue: 0.99)
        case .type: return Color(red: 0.42, green: 0.86, blue: 0.86)
        case .function: return Color(red: 0.47, green: 0.74, blue: 0.99)
        case .attribute: return Color(red: 0.99, green: 0.62, blue: 0.40)
        case .tag: return Color(red: 0.99, green: 0.47, blue: 0.66)
        case .property: return Color(red: 0.55, green: 0.85, blue: 0.65)
        }
    }

    private static let cache = NSCache<NSString, HighlightBox>()
    private final class HighlightBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    static func highlight(_ code: String, language: String) -> AttributedString {
        let key = "\(language)\u{0}\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let ns = code as NSString
        var result = AttributedString()
        var cursor = 0
        for token in SyntaxTokenizer.tokenize(code, language: language) {
            if token.range.location > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            }
            var piece = AttributedString(ns.substring(with: token.range))
            piece.foregroundColor = color(token.kind)
            if token.kind == .comment { piece.inlinePresentationIntent = .emphasized }
            result += piece
            cursor = token.range.location + token.range.length
        }
        if cursor < ns.length { result += AttributedString(ns.substring(from: cursor)) }
        cache.setObject(HighlightBox(result), forKey: key)
        return result
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    var isStreaming = false

    @Environment(\.codeActions) private var actions
    @State private var copied = false
    @State private var wrap = false

    private var lang: String { SyntaxTokenizer.normalize(language) }
    private var canRun: Bool { !isStreaming && ["javascript", "python"].contains(lang) && actions.run != nil }
    private var canPreview: Bool {
        !isStreaming && actions.preview != nil && (["html", "svg", "jsx", "tsx", "react", "mermaid"].contains(language.lowercased()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if canPreview {
                    Button { Haptics.tap(); actions.preview?(language, code) } label: {
                        Label("Preview", systemImage: "play.rectangle").font(.caption.weight(.semibold))
                    }
                }
                if canRun {
                    Button { Haptics.tap(); actions.run?(lang, code) } label: {
                        Label("Run", systemImage: "play.fill").font(.caption.weight(.semibold))
                    }
                }
                Button { withAnimation(Motion.snappy) { wrap.toggle() } } label: {
                    Image(systemName: wrap ? "arrow.left.and.right.text.vertical" : "text.alignleft").font(.caption)
                }
                Button {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    withAnimation(Motion.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.04))

            Group {
                if wrap {
                    codeText.padding(14)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        codeText.fixedSize(horizontal: true, vertical: false).padding(14)
                    }
                }
            }
        }
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var codeText: some View {
        Text(SyntaxTheme.highlight(code, language: language))
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.9))
            .lineSpacing(3)
            .textSelection(.enabled)
    }
}
