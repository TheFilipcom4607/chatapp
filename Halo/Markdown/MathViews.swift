import SwiftUI
import SwiftMath

enum MathRenderer {
    struct Rendered {
        let image: UIImage
        let descent: CGFloat
    }

    private final class Box { let value: Rendered; init(_ v: Rendered) { value = v } }
    private static let cache = NSCache<NSString, Box>()

    /// Renders LaTeX to an image with SwiftMath; nil if the LaTeX can't be parsed.
    static func render(latex: String, fontSize: CGFloat, display: Bool, color: UIColor = .white) -> Rendered? {
        let key = "\(display)|\(fontSize)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: color,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let rendered = Rendered(image: image, descent: layout?.descent ?? 0)
        cache.setObject(Box(rendered), forKey: key)
        return rendered
    }
}

struct MathBlockView: View {
    let latex: String

    var body: some View {
        if let r = MathRenderer.render(latex: latex, fontSize: 20, display: true) {
            ViewThatFits(in: .horizontal) {
                Image(uiImage: r.image)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .center)
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: r.image).padding(.vertical, 4)
                }
            }
        } else {
            Text(latex)
                .font(.callout.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
