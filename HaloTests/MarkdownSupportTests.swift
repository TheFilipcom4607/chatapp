import XCTest
@testable import Halo

final class MarkdownSupportTests: XCTestCase {

    func testInlineMath() {
        let out = MathPreprocessor.process("Euler: $e^{i\\pi}+1=0$ costs $5 and $10.")
        XCTAssertTrue(out.contains("`\(MathPreprocessor.inlineMarker)e^{i\\pi}+1=0`"))
        XCTAssertTrue(out.contains("$5 and $10"))
    }

    func testParenMath() {
        let out = MathPreprocessor.process("Area \\(\\pi r^2\\) ok")
        XCTAssertTrue(out.contains("`\(MathPreprocessor.inlineMarker)\\pi r^2`"))
    }

    func testDisplayMath() {
        let out = MathPreprocessor.process("Before\n$$\n\\int_0^1 x\\,dx\n$$\nAfter")
        XCTAssertTrue(out.contains("```math\n\\int_0^1 x\\,dx\n```"))
        XCTAssertTrue(out.hasPrefix("Before\n"))
        XCTAssertTrue(out.hasSuffix("After"))
        let single = MathPreprocessor.process("$$a+b$$")
        XCTAssertEqual(single, "```math\na+b\n```")
    }

    func testMathIgnoredInCode() {
        let input = "```bash\necho $HOME $PATH\n```\nand `$x$` stays"
        XCTAssertEqual(MathPreprocessor.process(input), input)
    }

    func testUnterminatedDisplayMathWhileStreaming() {
        let out = MathPreprocessor.process("$$\n\\frac{a}{b")
        XCTAssertTrue(out.contains("```math\n\\frac{a}{b\n```"))
    }

    func testTokenizerSwift() {
        let code = "// hi\nlet x = \"str\" + 42\nfunc foo() { print(x) }"
        let tokens = SyntaxTokenizer.tokenize(code, language: "swift")
        let ns = code as NSString
        func kinds(_ text: String) -> [SyntaxTokenizer.Kind] {
            tokens.filter { ns.substring(with: $0.range) == text }.map(\.kind)
        }
        XCTAssertEqual(kinds("// hi"), [.comment])
        XCTAssertEqual(kinds("let"), [.keyword])
        XCTAssertEqual(kinds("\"str\""), [.string])
        XCTAssertEqual(kinds("42"), [.number])
        XCTAssertEqual(kinds("print"), [.function])
    }

    func testTokenizerPythonAndHTML() {
        let py = "def f():\n    return 'a # not comment'  # real"
        let t = SyntaxTokenizer.tokenize(py, language: "py")
        let ns = py as NSString
        XCTAssertTrue(t.contains { ns.substring(with: $0.range) == "'a # not comment'" && $0.kind == .string })
        XCTAssertTrue(t.contains { ns.substring(with: $0.range) == "# real" && $0.kind == .comment })

        let html = "<div class=\"a\">hi</div>"
        let h = SyntaxTokenizer.tokenize(html, language: "html")
        let hs = html as NSString
        XCTAssertTrue(h.contains { hs.substring(with: $0.range) == "div" && $0.kind == .tag })
        XCTAssertTrue(h.contains { hs.substring(with: $0.range) == "class" && $0.kind == .attribute })
    }

    func testTokensDoNotOverlap() {
        let code = "const s = `a ${b}`; /* c */ x(1)"
        let tokens = SyntaxTokenizer.tokenize(code, language: "js")
        var covered = Set<Int>()
        for t in tokens {
            for i in t.range.location..<(t.range.location + t.range.length) {
                XCTAssertFalse(covered.contains(i))
                covered.insert(i)
            }
        }
    }
}
