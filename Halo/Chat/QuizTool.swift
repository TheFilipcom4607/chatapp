import Foundation

/// A multiple-choice quiz the model wrote for the user to study with, and how they're doing on it.
/// It lives on the tool message, so answers survive relaunches; the model sees them only when the
/// user sends their results.
struct Quiz: Codable, Hashable, Sendable {
    struct Question: Codable, Hashable, Sendable {
        var prompt: String
        var options: [String]
        /// Index into `options` of the right answer.
        var answer: Int
        var explanation: String?

        /// Options that point at the others ("All of the above") or a True/False pair keep their places.
        var keepsOrder: Bool {
            let lowered = options.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            if Set(lowered) == ["true", "false"] || Set(lowered) == ["yes", "no"] { return true }
            return lowered.contains { o in
                o.contains("of the above") || o.contains("of these") || o.hasPrefix("both ") || o.hasPrefix("neither ")
            }
        }
    }

    /// One run through the quiz, or through the questions missed last time.
    struct Attempt: Codable, Hashable, Sendable {
        /// Indexes into `questions`, in the order they're asked.
        var order: [Int]
        /// For each asked question, the order its options are shown in (indexes into its options).
        var optionOrders: [[Int]]
        /// For each asked question, the option picked (an index into its options); nil until answered.
        var picks: [Int?]
        /// The question on screen; `order.count` once the results show.
        var current: Int
        var onlyMistakes: Bool
        /// The score was added to the history (on first reaching the results).
        var scored: Bool
        /// The results went to the chat.
        var resultsSent: Bool
    }

    struct Score: Codable, Hashable, Sendable {
        var correct: Int
        var total: Int
        var onlyMistakes: Bool
    }

    var title: String
    var questions: [Question]
    var attempt: Attempt
    /// Finished attempts, oldest first.
    var history: [Score]

    static let maxQuestions = 50
    static let maxOptions = 6
    static let letters = ["A", "B", "C", "D", "E", "F"]

    init(title: String, questions: [Question]) {
        self.title = title
        self.questions = questions
        self.history = []
        self.attempt = Self.attempt(of: Array(questions.indices), in: questions, shuffleQuestions: false, onlyMistakes: false)
    }

    /// A fresh attempt. Options are always shuffled (models tend to put the right one second or
    /// third); questions only on a retry, so the first run keeps the model's easy-to-hard order.
    static func attempt(of indexes: [Int], in questions: [Question], shuffleQuestions: Bool, onlyMistakes: Bool) -> Attempt {
        let order = shuffleQuestions ? indexes.shuffled() : indexes
        let optionOrders = order.map { i -> [Int] in
            let q = questions[i]
            return q.keepsOrder ? Array(q.options.indices) : Array(q.options.indices).shuffled()
        }
        return Attempt(order: order, optionOrders: optionOrders, picks: Array(repeating: nil, count: order.count),
                       current: 0, onlyMistakes: onlyMistakes, scored: false, resultsSent: false)
    }

    // MARK: Progress

    var isShowingResults: Bool { attempt.current >= attempt.order.count }
    var answeredCount: Int { attempt.picks.compactMap { $0 }.count }

    func question(at step: Int) -> Question? {
        attempt.order.indices.contains(step) ? questions[attempt.order[step]] : nil
    }

    /// Whether the pick at a step was right; nil while it's unanswered.
    func isCorrect(at step: Int) -> Bool? {
        guard let q = question(at: step), let pick = attempt.picks[step] else { return nil }
        return pick == q.answer
    }

    var correctCount: Int { attempt.order.indices.filter { isCorrect(at: $0) == true }.count }

    /// Steps answered wrongly in this attempt, in the order they were asked.
    var missedSteps: [Int] { attempt.order.indices.filter { isCorrect(at: $0) == false } }

    /// The first unanswered step after the current one, wrapping round; nil when all are answered.
    var nextUnanswered: Int? {
        let n = attempt.order.count
        guard n > 0 else { return nil }
        return (1...n).map { (attempt.current + $0) % n }.first { attempt.picks[$0] == nil }
    }

    // MARK: Changes

    /// Records the option shown at `shownIndex` for the current question; a question is answered once.
    mutating func pick(shownIndex: Int) {
        let step = attempt.current
        guard attempt.picks.indices.contains(step), attempt.picks[step] == nil,
              attempt.optionOrders[step].indices.contains(shownIndex) else { return }
        attempt.picks[step] = attempt.optionOrders[step][shownIndex]
    }

    mutating func go(to step: Int) {
        attempt.current = min(max(0, step), attempt.order.count)
        if isShowingResults { scoreIfNeeded() }
    }

    /// Moves on to the next unanswered question, or to the results once everything's answered.
    mutating func advance() {
        go(to: nextUnanswered ?? attempt.order.count)
    }

    private mutating func scoreIfNeeded() {
        guard !attempt.scored, answeredCount == attempt.order.count else { return }
        attempt.scored = true
        history.append(Score(correct: correctCount, total: attempt.order.count, onlyMistakes: attempt.onlyMistakes))
    }

    /// Starts again with every question, or with just the ones missed this time, in a new order.
    mutating func retry(onlyMistakes: Bool) {
        let indexes = onlyMistakes ? missedSteps.map { attempt.order[$0] } : Array(questions.indices)
        guard !indexes.isEmpty else { return }
        attempt = Self.attempt(of: indexes, in: questions, shuffleQuestions: true, onlyMistakes: onlyMistakes)
    }

    // MARK: Results for the chat

    /// What the user sends to the model from the results, so it can go over the mistakes.
    var resultsMessage: String {
        let total = attempt.order.count
        let correct = correctCount
        let percent = total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : 0
        var lines = [attempt.onlyMistakes
            ? "My quiz results for \"\(title)\", retrying the questions I missed: \(correct)/\(total) (\(percent)%)."
            : "My quiz results for \"\(title)\": \(correct)/\(total) (\(percent)%)."]
        let earlier = history.dropLast(attempt.scored ? 1 : 0)
        if !earlier.isEmpty {
            lines.append("Earlier attempts: " + earlier.map { "\($0.correct)/\($0.total)\($0.onlyMistakes ? " (missed ones only)" : "")" }.joined(separator: ", ") + ".")
        }
        let missed = missedSteps
        if missed.isEmpty {
            lines.append("")
            lines.append("I got everything right. Give me a harder quiz on this topic.")
        } else {
            lines.append("")
            lines.append("What I got wrong:")
            for (n, step) in missed.enumerated() {
                guard let q = question(at: step), let pick = attempt.picks[step] else { continue }
                lines.append("\(n + 1). \(Self.oneLine(q.prompt))")
                lines.append("   My answer: \(Self.oneLine(q.options[pick]))")
                lines.append("   Right answer: \(Self.oneLine(q.options[q.answer]))")
            }
            lines.append("")
            lines.append("Go over what I got wrong, then quiz me again on those points.")
        }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Builds a quiz from `create_quiz`'s arguments, forgiving the usual slips: letters on the options,
/// the answer given as a letter or as the option's text, and a question or two that doesn't work.
enum QuizTool {
    static func make(_ args: JSONValue) -> ToolOutcome {
        let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = args["questions"]?.arrayValue ?? []
        var questions: [Quiz.Question] = []
        var skipped = 0
        for item in raw.prefix(Quiz.maxQuestions) {
            if let q = question(item) { questions.append(q) } else { skipped += 1 }
        }
        skipped += max(0, raw.count - Quiz.maxQuestions)
        guard !questions.isEmpty else {
            return .failure("""
            No usable questions. Each one needs `question`, `options` (2 to \(Quiz.maxOptions) strings, without letters) \
            and `correct_index` (the right option's index in `options`, counting from 0).
            """, summary: "No questions")
        }
        let quiz = Quiz(title: title.isEmpty ? "Quiz" : title, questions: questions)
        let count = "\(questions.count) question\(questions.count == 1 ? "" : "s")"
        var text = """
        The quiz "\(quiz.title)" (\(count)) is shown to the user as an interactive card. They answer one question at a time, \
        see right or wrong with your explanation after each, and get a score at the end; they can retry it or just the ones they missed. \
        Don't repeat the questions or answers in your reply: a short line to start them off is enough. \
        Their answers reach you only if they send their results from the card.
        """
        if skipped > 0 {
            text += "\n\(skipped) question\(skipped == 1 ? " was" : "s were") left out: \(Quiz.maxQuestions) at most, each with 2 to \(Quiz.maxOptions) options and a valid correct_index."
        }
        return ToolOutcome(text: text, summary: "\(quiz.title) · \(count)", quiz: quiz)
    }

    static func question(_ item: JSONValue) -> Quiz.Question? {
        let prompt = (item["question"] ?? item["prompt"])?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let given = (item["options"] ?? item["choices"])?.arrayValue?.compactMap(\.stringValue) ?? []
        let options = stripLetters(given.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !prompt.isEmpty, (2...Quiz.maxOptions).contains(options.count), !options.contains(where: \.isEmpty),
              let answer = answerIndex(item, options: options, original: given) else { return nil }
        let explanation = item["explanation"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Quiz.Question(prompt: prompt, options: options, answer: answer,
                             explanation: explanation?.isEmpty == false ? explanation : nil)
    }

    /// The right option from `correct_index`, or from a letter or the option's own text.
    private static func answerIndex(_ item: JSONValue, options: [String], original: [String]) -> Int? {
        let value = item["correct_index"] ?? item["answer_index"] ?? item["correct"] ?? item["answer"]
        guard let value else { return nil }
        if case .number = value, let i = value.intValue { return options.indices.contains(i) ? i : nil }
        guard let s = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let i = Int(s) { return options.indices.contains(i) ? i : nil }
        let letter = s.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "().: "))
        if letter.count == 1, let i = Quiz.letters.firstIndex(of: letter), options.indices.contains(i) { return i }
        if let i = options.firstIndex(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return i }
        return original.firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(s) == .orderedSame }
    }

    /// Drops "A) ", "B. ", "(c) " from the options when every one of them is lettered in order:
    /// the card adds its own letters and shuffles.
    static func stripLetters(_ options: [String]) -> [String] {
        var stripped: [String] = []
        for (i, option) in options.enumerated() {
            guard i < Quiz.letters.count else { return options }
            let letter = Quiz.letters[i]
            let patterns = ["\(letter)) ", "\(letter). ", "\(letter): ", "(\(letter)) ", "\(letter.lowercased())) ", "\(letter.lowercased()). ", "(\(letter.lowercased())) "]
            guard let p = patterns.first(where: { option.hasPrefix($0) }) else { return options }
            stripped.append(String(option.dropFirst(p.count)).trimmingCharacters(in: .whitespaces))
        }
        return stripped
    }
}
