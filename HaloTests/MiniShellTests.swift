import XCTest
@testable import Halo

final class MiniShellTests: XCTestCase {

    func testQuotingAndVariables() async {
        let r = await MiniShell.run(#"NAME='a b'; echo "hi $NAME" '$NAME' ${NAME}x"#)
        XCTAssertEqual(r.stdout, "hi a b $NAME a bx\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    func testPipesAndJoiners() async {
        let r = await MiniShell.run("printf 'b\\na\\nb\\n' | sort | uniq -c | head -1 && false || echo fallback")
        XCTAssertEqual(r.stdout, "      1 a\nfallback\n")
    }

    func testRedirectsAndUnknownCommands() async {
        let quiet = await MiniShell.run("nope 2>/dev/null; echo $?")
        XCTAssertEqual(quiet.stdout, "127\n")
        XCTAssertTrue(quiet.stderr.isEmpty)
        let file = await MiniShell.run("echo hi > out.txt")
        XCTAssertEqual(file.exitCode, 2)
        XCTAssertTrue(file.stderr.contains("no filesystem"))
    }

    func testGrep() async {
        let r = await MiniShell.run("echo -e 'Alpha\\nbeta\\ngamma' | grep -i -n 'a$\\|^b'")
        XCTAssertEqual(r.stdout, "1:Alpha\n2:beta\n3:gamma\n")
        let none = await MiniShell.run("echo x | grep y")
        XCTAssertEqual(none.exitCode, 1)
    }

    func testJQ() throws {
        let json = #"{"name":"swift","owner":{"login":"apple"},"tags":[{"n":"a"},{"n":"b"},{"n":"c"}]}"#
        XCTAssertEqual(try MiniJQ.run(filter: ".owner.login", input: json, raw: true, compact: false), "apple\n")
        XCTAssertEqual(try MiniJQ.run(filter: ".tags[].n", input: json, raw: true, compact: false), "a\nb\nc\n")
        XCTAssertEqual(try MiniJQ.run(filter: "[.tags[1:] | .[] | .n]", input: json, raw: false, compact: true), #"["b","c"]"# + "\n")
        XCTAssertEqual(try MiniJQ.run(filter: "{name, who: .owner.login, count: (.tags | length)}", input: json, raw: false, compact: true),
                       #"{"count":3,"name":"swift","who":"apple"}"# + "\n")
        XCTAssertEqual(try MiniJQ.run(filter: ".tags | map(.n) | last", input: json, raw: true, compact: false), "c\n")
        XCTAssertEqual(try MiniJQ.run(filter: ".missing.deeper", input: json, raw: false, compact: false), "null\n")
        XCTAssertThrowsError(try MiniJQ.run(filter: ".name.x", input: json, raw: false, compact: false))
        XCTAssertEqual(try MiniJQ.run(filter: ".name.x?", input: json, raw: false, compact: false), "")
        XCTAssertEqual(try MiniJQ.run(filter: ".name | keys?", input: json, raw: false, compact: false), "")
        XCTAssertEqual(try MiniJQ.run(filter: "type, length, keys?", input: "[1]", raw: false, compact: true), "\"array\"\n1\n[0]\n")
    }

    func testForLoopsSedTrCut() async {
        let loop = await MiniShell.run("X='a b'; for w in $X c; do echo \"[$w]\"; done && echo ok")
        XCTAssertEqual(loop.stdout, "[a]\n[b]\n[c]\nok\n")
        let sed = await MiniShell.run("echo '<loc>https://a.com/</loc>' | sed 's/<[^>]*>//g'; printf 'a b\\nc d\\n' | sed -n '2p' | sed 's/\\(.\\) \\(.\\)/\\2-\\1/'")
        XCTAssertEqual(sed.stdout, "https://a.com/\nd-c\n")
        let crlf = await MiniShell.run("printf 'HTTP/2 200\\r\\ncontent-type: text/html\\r\\n' | grep -i content-type | cut -d: -f2 | tr -d ' ' | tr a-z A-Z")
        XCTAssertEqual(crlf.stdout, "TEXT/HTML\n")
    }

    func testJQOperators() throws {
        let json = #"{"items":[{"name":"a","d":null,"n":3},{"name":"b","d":"long text","n":10}]}"#
        XCTAssertEqual(try MiniJQ.run(filter: ".items[] | [.name, (.d // \"-\" | .[0:4]), (.n|tostring)] | @tsv", input: json, raw: true, compact: false),
                       "a\t-\t3\nb\tlong\t10\n")
        XCTAssertEqual(try MiniJQ.run(filter: ".items[] | select(.n > 5 and .d != null) | .name", input: json, raw: true, compact: false), "b\n")
        XCTAssertEqual(try MiniJQ.run(filter: ".items | sort_by(.n) | map(.name) | join(\",\")", input: json, raw: true, compact: false), "a,b\n")
        XCTAssertEqual(try MiniJQ.run(filter: "[.items[].n] | add", input: json, raw: false, compact: false), "13\n")
    }

    func testCurlArgumentErrors() async {
        let noURL = await MiniShell.run("curl -s")
        XCTAssertTrue(noURL.stderr.contains("no URL"))
        let file = await MiniShell.run("curl -o page.html https://example.com")
        XCTAssertEqual(file.exitCode, 23)
    }

    func testOnlyCurlAndWgetReachTheNetwork() {
        XCTAssertFalse(MiniShell.reachesNetwork("date"))
        XCTAssertFalse(MiniShell.reachesNetwork("echo '{\"a\":1}' | jq .a && printf 'curl\\n'"))
        XCTAssertTrue(MiniShell.reachesNetwork("curl -s https://example.com | head -5"))
        XCTAssertTrue(MiniShell.reachesNetwork("echo hi; wget -qO- https://example.com"))
        XCTAssertTrue(MiniShell.reachesNetwork("CMD=curl; $CMD https://example.com"))
        XCTAssertTrue(MiniShell.reachesNetwork("echo 'unclosed"))
    }
}
