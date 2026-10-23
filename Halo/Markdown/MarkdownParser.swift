import Foundation
import Markdown

// Own block/inline model so the SwiftUI layer never imports `Markdown`
// (its `Text`/`Image` types clash with SwiftUI's).

indirect enum MDInline: Hashable {
    case text(String)
    case emphasis([MDInline])
    case strong([MDInline])
    case strike([MDInline])
    case code(String)
    case math(String)
    case link(String, [MDInline])
    case image(String, String)
    case lineBreak
    case softBreak
}

enum MDAlign: Hashable { case left, center, right }

struct MDListItem: Hashable {
    var checkbox: Bool?
    var blocks: [MDBlock]
}

indirect enum MDBlock: Hashable {
    case heading(Int, [MDInline])
    case paragraph([MDInline])
    case code(String, String)          // language, code
    case math(String)
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case quote([MDBlock])
    case table(head: [[MDInline]], rows: [[[MDInline]]], align: [MDAlign])
    case rule
    case html(String)
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        let processed = MathPreprocessor.process(text)
        let document = Document(parsing: processed)
        return document.children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> MDBlock? {
        switch markup {
        case let h as Heading:
            return .heading(h.level, inlines(h))
        case let p as Paragraph:
            return .paragraph(inlines(p))
        case let c as CodeBlock:
            let lang = (c.language ?? "").trimmingCharacters(in: .whitespaces)
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            if lang == "math" || lang == "latex" && !code.contains("\\documentclass") { return .math(code) }
            return .code(lang, code)
        case let l as UnorderedList:
            return .list(ordered: false, start: 1, items: l.listItems.map(listItem))
        case let l as OrderedList:
            return .list(ordered: true, start: Int(l.startIndex), items: l.listItems.map(listItem))
        case let q as BlockQuote:
            return .quote(q.children.compactMap(block))
        case let t as Table:
            let head = t.head.cells.map { inlines($0) }
            let rows = t.body.rows.map { row in row.cells.map { inlines($0) } }
            let align: [MDAlign] = t.columnAlignments.map {
                switch $0 {
                case .center: return .center
                case .right: return .right
                default: return .left
                }
            }
            return .table(head: Array(head), rows: Array(rows), align: align)
        case is ThematicBreak:
            return .rule
        case let h as HTMLBlock:
            let raw = h.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : .html(raw)
        default:
            let inl = inlines(markup)
            return inl.isEmpty ? nil : .paragraph(inl)
        }
    }

    private static func listItem(_ item: ListItem) -> MDListItem {
        var box: Bool? = nil
        if let c = item.checkbox { box = (c == .checked) }
        return MDListItem(checkbox: box, blocks: item.children.compactMap(block))
    }

    private static func inlines(_ markup: Markup) -> [MDInline] {
        markup.children.compactMap(inline)
    }

    private static func inline(_ markup: Markup) -> MDInline? {
        switch markup {
        case let t as Markdown.Text: return .text(t.string)
        case let e as Emphasis: return .emphasis(inlines(e))
        case let s as Strong: return .strong(inlines(s))
        case let s as Strikethrough: return .strike(inlines(s))
        case let c as InlineCode:
            if c.code.hasPrefix(MathPreprocessor.inlineMarker) {
                return .math(String(c.code.dropFirst(MathPreprocessor.inlineMarker.count)))
            }
            return .code(c.code)
        case let l as Link: return .link(l.destination ?? "", inlines(l))
        case let i as Markdown.Image: return .image(i.source ?? "", i.plainText)
        case is LineBreak: return .lineBreak
        case is SoftBreak: return .softBreak
        case let h as InlineHTML:
            let raw = h.rawHTML.lowercased()
            if raw == "<br>" || raw == "<br/>" || raw == "<br />" { return .lineBreak }
            return .text(h.rawHTML)
        default:
            let children = inlines(markup)
            return children.isEmpty ? nil : .text(children.map(\.plainText).joined())
        }
    }
}

extension MDInline {
    var plainText: String {
        switch self {
        case .text(let s), .code(let s), .math(let s): return s
        case .emphasis(let c), .strong(let c), .strike(let c), .link(_, let c): return c.map(\.plainText).joined()
        case .image(_, let alt): return alt
        case .lineBreak, .softBreak: return "\n"
        }
    }
}
