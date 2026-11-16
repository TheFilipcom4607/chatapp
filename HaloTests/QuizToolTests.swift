import XCTest
@testable import Halo

@MainActor
final class QuizToolTests: XCTestCase {

    private func args(_ questions: [JSONValue], title: String = "Cells") -> JSONValue {
        ["title": .string(title), "questions": .array(questions)]
    }

    private let mitochondria: JSONValue = [
        "question": "Which organelle makes most of a cell's ATP?",
        "options": ["Ribosome", "Mitochondrion", "Golgi apparatus", "Lysosome"],
        "correct_index": 1,
        "explanation": "Cellular respiration happens in the **mitochondrion**.",
    ]

    func testBuildsAQuizAndTellsTheModelNotToRepeatIt() {
        let outcome = QuizTool.make(args([mitochondria]))
        XCTAssertTrue(outcome.ok)
        let quiz = try! XCTUnwrap(outcome.quiz)
        XCTAssertEqual(quiz.title, "Cells")
        XCTAssertEqual(quiz.questions.count, 1)
        XCTAssertEqual(quiz.questions[0].answer, 1)
        XCTAssertEqual(quiz.questions[0].options[quiz.questions[0].answer], "Mitochondrion")
        XCTAssertEqual(outcome.summary, "Cells · 1 question")
        XCTAssertTrue(outcome.text.contains("Don't repeat the questions"))
        // Every option is shown exactly once.
        XCTAssertEqual(quiz.attempt.optionOrders[0].sorted(), [0, 1, 2, 3])
    }

    func testForgivesLetteredOptionsAndLetterOrTextAnswers() {
        let lettered: JSONValue = ["question": "2 + 2?", "options": ["A) 3", "B) 4", "C) 5"], "correct": "B"]
        let byText: JSONValue = ["question": "Capital of France?", "options": ["Lyon", "Paris"], "answer": "paris"]
        let quiz = try! XCTUnwrap(QuizTool.make(args([lettered, byText])).quiz)
        XCTAssertEqual(quiz.questions[0].options, ["3", "4", "5"])
        XCTAssertEqual(quiz.questions[0].answer, 1)
        XCTAssertEqual(quiz.questions[1].answer, 1)
        XCTAssertNil(quiz.questions[1].explanation)
    }

    func testKeepsAHintAndDropsAnEmptyOne() {
        let withHint: JSONValue = ["question": "Powerhouse?", "options": ["Mitochondrion", "Ribosome"], "correct_index": 0, "hint": "Think powerhouse."]
        let emptyHint: JSONValue = ["question": "Protein factory?", "options": ["Mitochondrion", "Ribosome"], "correct_index": 1, "hint": "  "]
        let quiz = try! XCTUnwrap(QuizTool.make(args([withHint, emptyHint])).quiz)
        XCTAssertEqual(quiz.questions[0].hint, "Think powerhouse.")
        XCTAssertNil(quiz.questions[1].hint)
    }

    func testAskMessageNamesThePickAndTheAnswer() {
        var quiz = sampleQuiz()
        XCTAssertNil(quiz.askMessage(at: 0), "Nothing to ask before answering")
        answer(&quiz, with: 0)          // France: right
        answer(&quiz, with: 0)          // Spain: wrong (Seville)
        XCTAssertEqual(quiz.askMessage(at: 1), """
        About this question from my quiz "Capitals": Spain?
        I answered Seville, but the right answer is Madrid.
        Explain why, and how to tell the two apart next time.
        """)
        XCTAssertTrue(quiz.askMessage(at: 0)!.contains("I got it right: Paris."))
    }

    func testOnlyStripsLettersWhenEveryOptionHasThemInOrder() {
        XCTAssertEqual(QuizTool.stripLetters(["A. Lincoln", "Washington"]), ["A. Lincoln", "Washington"])
        XCTAssertEqual(QuizTool.stripLetters(["(a) one", "(b) two"]), ["one", "two"])
    }

    func testDropsBrokenQuestionsAndSaysSo() {
        let oneOption: JSONValue = ["question": "Only one?", "options": ["Yes"], "correct_index": 0]
        let outOfRange: JSONValue = ["question": "Bad index", "options": ["a", "b"], "correct_index": 2]
        let outcome = QuizTool.make(args([mitochondria, oneOption, outOfRange]))
        XCTAssertEqual(outcome.quiz?.questions.count, 1)
        XCTAssertTrue(outcome.text.contains("2 questions were left out"))
    }

    func testFailsWithoutAnyUsableQuestion() {
        let outcome = QuizTool.make(args([["question": "No options", "correct_index": 0]]))
        XCTAssertFalse(outcome.ok)
        XCTAssertNil(outcome.quiz)
        XCTAssertTrue(outcome.text.contains("correct_index"))
    }

    func testTrueFalseAndAllOfTheAboveKeepTheirOrder() {
        XCTAssertTrue(Quiz.Question(prompt: "?", options: ["True", "False"], answer: 0).keepsOrder)
        XCTAssertTrue(Quiz.Question(prompt: "?", options: ["Red", "Blue", "All of the above"], answer: 2).keepsOrder)
        XCTAssertFalse(Quiz.Question(prompt: "?", options: ["Red", "Blue", "Green"], answer: 2).keepsOrder)
        let quiz = Quiz(title: "T", questions: [Quiz.Question(prompt: "?", options: ["Red", "Blue", "None of the above"], answer: 2)])
        XCTAssertEqual(quiz.attempt.optionOrders[0], [0, 1, 2])
    }

    /// Picks the option shown for `option` (an index into the question's own options).
    private func answer(_ quiz: inout Quiz, with option: Int) {
        let shown = quiz.attempt.optionOrders[quiz.attempt.current].firstIndex(of: option)!
        quiz.pick(shownIndex: shown)
        quiz.advance()
    }

    private func sampleQuiz() -> Quiz {
        Quiz(title: "Capitals", questions: [
            .init(prompt: "France?", options: ["Paris", "Lyon"], answer: 0, explanation: nil),
            .init(prompt: "Spain?", options: ["Seville", "Madrid"], answer: 1, explanation: nil),
            .init(prompt: "Italy?", options: ["Rome", "Milan"], answer: 0, explanation: nil),
        ])
    }

    func testScoresOnceAndRetriesJustTheMisses() {
        var quiz = sampleQuiz()
        XCTAssertEqual(quiz.attempt.order, [0, 1, 2], "The first run keeps the model's order")
        answer(&quiz, with: 0)          // France: right
        answer(&quiz, with: 0)          // Spain: wrong (Seville)
        XCTAssertFalse(quiz.isShowingResults)
        answer(&quiz, with: 0)          // Italy: right
        XCTAssertTrue(quiz.isShowingResults)
        XCTAssertEqual(quiz.correctCount, 2)
        XCTAssertEqual(quiz.history, [Quiz.Score(correct: 2, total: 3, onlyMistakes: false)])

        // Reviewing a question and coming back doesn't score the attempt twice.
        quiz.go(to: 1)
        quiz.advance()
        XCTAssertTrue(quiz.isShowingResults)
        XCTAssertEqual(quiz.history.count, 1)

        // A question is answered once.
        quiz.go(to: 1)
        quiz.pick(shownIndex: quiz.attempt.optionOrders[1].firstIndex(of: 1)!)
        XCTAssertEqual(quiz.isCorrect(at: 1), false)

        quiz.retry(onlyMistakes: true)
        XCTAssertEqual(quiz.attempt.order, [1])
        XCTAssertTrue(quiz.attempt.onlyMistakes)
        XCTAssertEqual(quiz.attempt.current, 0)
        answer(&quiz, with: 1)
        XCTAssertTrue(quiz.isShowingResults)
        XCTAssertEqual(quiz.history.last, Quiz.Score(correct: 1, total: 1, onlyMistakes: true))
    }

    func testSkippingAheadComesBackForUnansweredQuestions() {
        var quiz = sampleQuiz()
        quiz.go(to: 2)
        answer(&quiz, with: 0)
        XCTAssertEqual(quiz.attempt.current, 0, "Wraps round to the first unanswered question")
        answer(&quiz, with: 0)
        XCTAssertEqual(quiz.attempt.current, 1)
        answer(&quiz, with: 1)
        XCTAssertTrue(quiz.isShowingResults)
        XCTAssertEqual(quiz.correctCount, 3)
    }

    func testResultsMessageListsTheMisses() {
        var quiz = sampleQuiz()
        answer(&quiz, with: 0)
        answer(&quiz, with: 0)
        answer(&quiz, with: 1)
        let text = quiz.resultsMessage
        XCTAssertTrue(text.hasPrefix("My quiz results for \"Capitals\": 1/3 (33%)."))
        XCTAssertTrue(text.contains("1. Spain?\n   My answer: Seville\n   Right answer: Madrid"))
        XCTAssertTrue(text.contains("2. Italy?\n   My answer: Milan\n   Right answer: Rome"))
        XCTAssertTrue(text.hasSuffix("Go over what I got wrong, then quiz me again on those points."))

        var perfect = sampleQuiz()
        answer(&perfect, with: 0)
        answer(&perfect, with: 1)
        answer(&perfect, with: 0)
        XCTAssertTrue(perfect.resultsMessage.contains("Give me a harder quiz"))
    }

    func testQuizSurvivesTheToolStateRoundTripAndOldStatesStillDecode() throws {
        var quiz = sampleQuiz()
        answer(&quiz, with: 0)
        let state = ToolState(name: ToolName.createQuiz.rawValue, arguments: "{}", status: .done, quiz: quiz)
        let decoded = try JSONDecoder().decode(ToolState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.quiz, quiz)

        let old = #"{"name":"get_weather","arguments":"{}","status":"done","summary":"12°"}"#
        let oldState = try JSONDecoder().decode(ToolState.self, from: Data(old.utf8))
        XCTAssertNil(oldState.quiz)
    }

    func testOfferedOnlyWithTheQuizCapability() throws {
        func names(_ caps: Set<ToolCapability>) throws -> [String] {
            let data = try JSONEncoder().encode(ToolDefinitions.tools(for: caps, search: nil, modelID: "x"))
            let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            return tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
        XCTAssertTrue(try names([.quizzes]).contains("create_quiz"))
        XCTAssertFalse(try names([.code]).contains("create_quiz"))
    }
}
