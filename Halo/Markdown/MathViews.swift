import SwiftUI
import SwiftMath

enum MathRenderer {
    private static let cache = NSCache<NSString, UIImage>()

    /// Renders LaTeX to an image using SwiftMath; nil if the LaTeX is invalid.
    static func image(latex: String, fontSize: CGFloat, display: Bool, color: UIColor = .white) -> UIImage? {
        let key = "\(display)|\(fontSize)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = color
        label.labelMode = display ? .display : .text
        label.backgroundColor = .clear
        guard label.error == nil else { return nil }
        let size = label.sizeThatFits(CGSize(width: 4000, height: 4000))
        guard size.width > 1, size.height > 1 else { return nil }
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            label.draw(label.bounds)
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

struct MathBlockView: View {
    let latex: String

    var body: some View {
        Group {
            if let img = MathRenderer.image(latex: latex, fontSize: 20, display: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: img)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity, alignment: .center)
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
}
