import SwiftUI

/// Actions code blocks can trigger (run / preview), provided by the chat screen.
struct CodeActions {
    var run: ((String, String) -> Void)?      // language, code
    var preview: ((String, String) -> Void)?
}

private struct CodeActionsKey: EnvironmentKey {
    static let defaultValue = CodeActions()
}

extension EnvironmentValues {
    var codeActions: CodeActions {
        get { self[CodeActionsKey.self] }
        set { self[CodeActionsKey.self] = newValue }
    }
}

/// Parsed markdown is cached per text so scrolling never re-parses.
final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()
    private let cache = NSCache<NSString, Box>()
    private final class Box { let blocks: [MDBlock]; init(_ b: [MDBlock]) { blocks = b } }

    func blocks(for text: String) -> [MDBlock] {
        let key = text as NSString
        if let b = cache.object(forKey: key) { return b.blocks }
        let blocks = MarkdownParser.parse(text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    /// For text that is still growing: everything up to the last paragraph break is parsed once and
    /// cached, and only the unfinished tail is parsed on each update, so long replies stay smooth.
    /// The finished reply is parsed whole, which settles any difference at the seams.
    func streamingBlocks(for text: String) -> [MDBlock] {
        guard let split = Self.lastParagraphBreak(in: text) else { return MarkdownParser.parse(text) }
        return blocks(for: String(text[..<split])) + MarkdownParser.parse(String(text[split...]))
    }

    /// The start of the last blank line outside a code fence or display math, if any text precedes it.
    static func lastParagraphBreak(in text: String) -> String.Index? {
        var inFence = false
        var inMath = false
        var result: String.Index?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence, trimmed.components(separatedBy: "$$").count % 2 == 0 {
                inMath.toggle()   // an odd number of $$ opens or closes a display block
            } else if trimmed.isEmpty, !inFence, !inMath, line.startIndex > text.startIndex {
                result = line.startIndex
            }
        }
        return result
    }
}

struct MarkdownView: View {
    let text: String
    var isStreaming = false
    var baseFont: Font = .body

    var body: some View {
        let blocks = isStreaming ? MarkdownCache.shared.streamingBlocks(for: text) : MarkdownCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, isLast: index == blocks.count - 1, isStreaming: isStreaming)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .font(baseFont)
        .animation(isStreaming ? .easeOut(duration: 0.28) : nil, value: blocks.count)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BlockView: View {
    let block: MDBlock
    var isLast = false
    var isStreaming = false

    var body: some View {
        switch block {
        case let .heading(level, inl):
            InlineText(inlines: inl)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case let .paragraph(inl):
            InlineText(inlines: inl)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case let .code(lang, code):
            CodeBlockView(language: lang, code: code, isStreaming: isStreaming && isLast)
        case let .math(latex):
            MathBlockView(latex: latex)
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            if let checked = item.checkbox {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Theme.textPrimary : Theme.textTertiary)
                            } else if ordered {
                                Text("\(start + i).").monospacedDigit().foregroundStyle(Theme.textSecondary)
                            } else {
                                Circle().fill(Theme.textSecondary).frame(width: 5, height: 5).offset(y: -3)
                            }
                        }
                        .frame(minWidth: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, b in
                                BlockView(block: b)
                            }
                        }
                    }
                }
            }
        case let .quote(blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.fillStrong)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
                }
                .foregroundStyle(Theme.textSecondary)
            }
        case let .table(head, rows, align):
            TableBlockView(head: head, rows: rows, align: align)
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
        case let .html(raw):
            Text(raw).font(.callout.monospaced()).foregroundStyle(Theme.textSecondary)
        }
    }

    /// Never smaller than body text: the deepest levels are body-sized and bold.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.bold)
        case 3: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

// MARK: - Inline rendering

private enum InlineSegment {
    case attributed(AttributedString)
    case math(String)
}

struct InlineText: View {
    let inlines: [MDInline]
    @Environment(\.font) private var font

    var body: some View {
        let segments = Self.segments(inlines)
        if segments.count == 1, case .attributed(let a) = segments[0] {
            Text(a)
        } else {
            segments.reduce(Text("")) { result, seg in
                switch seg {
                case .attributed(let a):
                    return Text("\(result)\(Text(a))")
                case .math(let latex):
                    if let r = MathRenderer.render(latex: latex, fontSize: 17, display: false) {
                        let piece = Text(Image(uiImage: r.image)).baselineOffset(-r.descent)
                        return Text("\(result)\(piece)")
                    }
                    return Text("\(result)\(Text(latex).font(.body.monospaced()))")
                }
            }
        }
    }

    private static func segments(_ inlines: [MDInline]) -> [InlineSegment] {
        var out: [InlineSegment] = []
        var current = AttributedString()
        func flush() {
            if !current.characters.isEmpty { out.append(.attributed(current)); current = AttributedString() }
        }
        func append(_ inl: MDInline, intent: InlinePresentationIntent, link: URL?) {
            switch inl {
            case .text(let s):
                var a = AttributedString(s)
                if !intent.isEmpty { a.inlinePresentationIntent = intent }
                if let link { a.link = link; a.foregroundColor = Theme.textPrimary; a.underlineStyle = .single }
                current += a
            case .code(let s):
                var a = AttributedString(s)
                a.inlinePresentationIntent = intent.union(.code)
                a.backgroundColor = Color.white.opacity(0.1)
                a.foregroundColor = Color.white.opacity(0.92)
                current += a
            case .emphasis(let c): c.forEach { append($0, intent: intent.union(.emphasized), link: link) }
            case .strong(let c): c.forEach { append($0, intent: intent.union(.stronglyEmphasized), link: link) }
            case .strike(let c): c.forEach { append($0, intent: intent.union(.strikethrough), link: link) }
            case .link(let dest, let c):
                let url = URL(string: dest)
                if c.isEmpty { append(.text(dest), intent: intent, link: url) }
                else { c.forEach { append($0, intent: intent, link: url) } }
            case .image(let src, let alt):
                var a = AttributedString("[" + (alt.isEmpty ? "image" : alt) + "]")
                a.link = URL(string: src)
                a.foregroundColor = Theme.textSecondary
                current += a
            case .lineBreak: current += AttributedString("\n")
            case .softBreak: current += AttributedString(" ")
            case .math(let latex):
                flush()
                out.append(.math(latex))
            }
        }
        inlines.forEach { append($0, intent: [], link: nil) }
        flush()
        if out.isEmpty { out.append(.attributed(AttributedString())) }
        return out
    }
}

// MARK: - Tables

struct TableBlockView: View {
    let head: [[MDInline]]
    let rows: [[[MDInline]]]
    let align: [MDAlign]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(head.enumerated()), id: \.offset) { i, cell in
                        cellView(cell, column: i).font(.subheadline.weight(.semibold))
                            .background(Color.white.opacity(0.07))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    Divider().overlay(Theme.hairline).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                            cellView(cell, column: i).font(.subheadline)
                                .background(r % 2 == 1 ? Color.white.opacity(0.025) : .clear)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
        }
    }

    private func cellView(_ inl: [MDInline], column: Int) -> some View {
        let a = column < align.count ? align[column] : .left
        return InlineText(inlines: inl)
            .multilineTextAlignment(a == .right ? .trailing : a == .center ? .center : .leading)
            .frame(minWidth: 60, maxWidth: 280, alignment: a == .right ? .trailing : a == .center ? .center : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }
}
